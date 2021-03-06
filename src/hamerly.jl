"""
    Hamerly()

Hamerly algorithm implementation, based on "Hamerly, Greg. (2010). Making k-means Even Faster.
 Proceedings of the 2010 SIAM International Conference on Data Mining. 130-140. 10.1137/1.9781611972801.12."

This algorithm provides much faster convergence than Lloyd algorithm with realtively small increase in
memory footprint. It is especially suitable for low to medium dimensional input data.

It can be used directly in `kmeans` function

```julia
X = rand(30, 100_000)   # 100_000 random points in 30 dimensions

kmeans(Hamerly(), X, 3) # 3 clusters, Hamerly algorithm
```
"""
struct Hamerly <: AbstractKMeansAlg end


function kmeans!(alg::Hamerly, containers, X, k;
                n_threads = Threads.nthreads(),
                k_init = "k-means++", max_iters = 300,
                tol = 1e-6, verbose = false, init = nothing)
    nrow, ncol = size(X)
    centroids = init == nothing ? smart_init(X, k, n_threads, init=k_init).centroids : deepcopy(init)

    @parallelize n_threads ncol chunk_initialize(alg, containers, centroids, X)

    converged = false
    niters = 0
    J_previous = 0.0
    p = containers.p

    # Update centroids & labels with closest members until convergence
    while niters < max_iters
        niters += 1
        update_containers(alg, containers, centroids, n_threads)
        @parallelize n_threads ncol chunk_update_centroids(alg, containers, centroids, X)
        collect_containers(alg, containers, n_threads)

        J = sum(containers.ub)
        move_centers(alg, containers, centroids)

        r1, r2, pr1, pr2 = double_argmax(p)
        @parallelize n_threads ncol chunk_update_bounds(alg, containers, r1, r2, pr1, pr2)

        if verbose
            # Show progress and terminate if J stops decreasing as specified by the tolerance level.
            println("Iteration $niters: Jclust = $J")
        end

        # Check for convergence
        if (niters > 1) & (abs(J - J_previous) < (tol * J))
            converged = true
            break
        end

        J_previous = J
    end

    @parallelize n_threads ncol sum_of_squares(containers, X, containers.labels, centroids)
    totalcost = sum(containers.sum_of_squares)

    # Terminate algorithm with the assumption that K-means has converged
    if verbose & converged
        println("Successfully terminated with convergence.")
    end

    # TODO empty placeholder vectors should be calculated
    # TODO Float64 type definitions is too restrictive, should be relaxed
    # especially during GPU related development
    return KmeansResult(centroids, containers.labels, Float64[], Int[], Float64[], totalcost, niters, converged)
end


function collect_containers(alg::Hamerly, containers, n_threads)
    if n_threads == 1
        @inbounds containers.centroids_new[end] .= containers.centroids_new[1] ./ containers.centroids_cnt[1]'
    else
        @inbounds containers.centroids_new[end] .= containers.centroids_new[1]
        @inbounds containers.centroids_cnt[end] .= containers.centroids_cnt[1]
        @inbounds for i in 2:n_threads
            containers.centroids_new[end] .+= containers.centroids_new[i]
            containers.centroids_cnt[end] .+= containers.centroids_cnt[i]
        end

        @inbounds containers.centroids_new[end] .= containers.centroids_new[end] ./ containers.centroids_cnt[end]'
    end
end


function create_containers(alg::Hamerly, k, nrow, ncol, n_threads)
    lng = n_threads + 1
    centroids_new = Vector{Array{Float64,2}}(undef, lng)
    centroids_cnt = Vector{Vector{Int}}(undef, lng)

    for i = 1:lng
        centroids_new[i] = zeros(nrow, k)
        centroids_cnt[i] = zeros(k)
    end

    # Upper bound to the closest center
    ub = Vector{Float64}(undef, ncol)

    # lower bound to the second closest center
    lb = Vector{Float64}(undef, ncol)

    labels = zeros(Int, ncol)

    # distance that centroid moved
    p = Vector{Float64}(undef, k)

    # distance from the center to the closest other center
    s = Vector{Float64}(undef, k)

    # total_sum_calculation
    sum_of_squares = Vector{Float64}(undef, n_threads)

    return (
        centroids_new = centroids_new,
        centroids_cnt = centroids_cnt,
        labels = labels,
        ub = ub,
        lb = lb,
        p = p,
        s = s,
        sum_of_squares = sum_of_squares
    )
end

"""
    chunk_initialize(alg::Hamerly, containers, centroids, design_matrix, r, idx)

Initial calulation of all bounds and points labeling.
"""
function chunk_initialize(alg::Hamerly, containers, centroids, X, r, idx)
    centroids_cnt = containers.centroids_cnt[idx]
    centroids_new = containers.centroids_new[idx]

    @inbounds for i in r
        label = point_all_centers!(containers, centroids, X, i)
        centroids_cnt[label] += 1
        for j in axes(X, 1)
            centroids_new[j, label] += X[j, i]
        end
    end
end

"""
    update_containers(::Hamerly, containers, centroids, n_threads)

Calculates minimum distances from centers to each other.
"""
function update_containers(::Hamerly, containers, centroids, n_threads)
    s = containers.s
    s .= Inf
    @inbounds for i in axes(centroids, 2)
        for j in i+1:size(centroids, 2)
            d = distance(centroids, centroids, i, j)
            d = 0.25*d
            s[i] = s[i] > d ? d : s[i]
            s[j] = s[j] > d ? d : s[j]
        end
    end
end

"""
    chunk_update_centroids(::Hamerly, containers, centroids, X, r, idx)

Detailed description of this function can be found in the original paper. It iterates through
all points and tries to skip some calculation using known upper and lower bounds of distances
from point to centers. If it fails to skip than it fall back to generic `point_all_centers!` function.
"""
function chunk_update_centroids(alg::Hamerly, containers, centroids, X, r, idx)

    # unpack containers for easier manipulations
    centroids_new = containers.centroids_new[idx]
    centroids_cnt = containers.centroids_cnt[idx]
    labels = containers.labels
    s = containers.s
    lb = containers.lb
    ub = containers.ub

    @inbounds for i in r
        # m ← max(s(a(i))/2, l(i))
        m = max(s[labels[i]], lb[i])
        # first bound test
        if ub[i] > m
            # tighten upper bound
            label = labels[i]
            ub[i] = distance(X, centroids, i, label)
            # second bound test
            if ub[i] > m
                label_new = point_all_centers!(containers, centroids, X, i)
                if label != label_new
                    labels[i] = label_new
                    centroids_cnt[label_new] += 1
                    centroids_cnt[label] -= 1
                    for j in axes(X, 1)
                        centroids_new[j, label_new] += X[j, i]
                        centroids_new[j, label] -= X[j, i]
                    end
                end
            end
        end
    end
end

"""
    point_all_centers!(containers, centroids, X, i)

Calculates new labels and upper and lower bounds for all points.
"""
function point_all_centers!(containers, centroids, X, i)
    ub = containers.ub
    lb = containers.lb
    labels = containers.labels

    min_distance = Inf
    min_distance2 = Inf
    label = 1
    @inbounds for k in axes(centroids, 2)
        dist = distance(X, centroids, i, k)
        if min_distance > dist
            label = k
            min_distance2 = min_distance
            min_distance = dist
        elseif min_distance2 > dist
            min_distance2 = dist
        end
    end

    ub[i] = min_distance
    lb[i] = min_distance2
    labels[i] = label

    return label
end

"""
    move_centers(::Hamerly, containers, centroids)

Calculates new positions of centers and distance they have moved. Results are stored
in `centroids` and `p` respectively.
"""
function move_centers(::Hamerly, containers, centroids)
    centroids_new = containers.centroids_new[end]
    p = containers.p

    @inbounds for i in axes(centroids, 2)
        d = 0.0
        for j in axes(centroids, 1)
            d += (centroids[j, i] - centroids_new[j, i])^2
            centroids[j, i] = centroids_new[j, i]
        end
        p[i] = d
    end
end

"""
    chunk_update_bounds(alg::Hamerly, containers, r1, r2, pr1, pr2, r, idx)

Updates upper and lower bounds of point distance to the centers, with regard to the centers movement.
"""
function chunk_update_bounds(alg::Hamerly, containers, r1, r2, pr1, pr2, r, idx)
    p = containers.p
    ub = containers.ub
    lb = containers.lb
    labels = containers.labels

    # Since bounds are squred distance, `sqrt` is used to make corresponding estimation, unlike
    # the original paper, where usual metric is used.
    #
    # Using notation from original paper, `u` is upper bound and `a` is `labels`, so
    #
    # `u[i] -> u[i] + p[a[i]]`
    #
    # then squared distance is
    #
    # `u[i]^2 -> (u[i] + p[a[i]])^2 = u[i]^2 + 2 p[a[i]] u[i] + p[a[i]]^2`
    #
    # Taking into account that in our noations `p^2 -> p`, `u^2 -> ub` we obtain
    #
    # `ub[i] -> ub[i] + 2 sqrt(p[a[i]] ub[i]) + p[a[i]]`
    #
    # The same applies to the lower bounds.
    @inbounds for i in r
        label = labels[i]
        ub[i] += 2*sqrt(abs(ub[i] * p[label])) + p[label]
        if r1 == label
            lb[i] += pr2 - 2*sqrt(abs(pr2*lb[i]))
        else
            lb[i] += pr1 - 2*sqrt(abs(pr1*lb[i]))
        end
    end
end

"""
    double_argmax(p)

Finds maximum and next after maximum arguments.
"""
function double_argmax(p)
    r1, r2 = 1, 1
    d1 = p[1]
    d2 = -1.0
    for i in 2:length(p)
        if p[i] > d1
            r2 = r1
            r1 = i
            d2 = d1
            d1 = p[i]
        elseif p[i] > d2
            d2 = p[i]
            r2 = i
        end
    end

    r1, r2, d1, d2
end
