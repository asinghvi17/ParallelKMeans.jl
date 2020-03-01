module TestKMeans

using ParallelKMeans
using ParallelKMeans: MultiThread
using Test
using Random

# TODO add tests where methods do not converge
# TODO add tests on the number of iterations before test converge
@testset "basic kmeans" begin
    X = [1. 2. 4.;]
    res = kmeans(X, 1; tol = 1e-6, verbose = false)
    @test res.assignments == [1, 1, 1]
    @test res.centers[1] ≈ 2.3333333333333335
    @test res.totalcost ≈ 4.666666666666666
    @test res.converged

    res = kmeans(X, 2; init = [1.0 4.0], tol = 1e-6, verbose = false)
    @test res.assignments == [1, 1, 2]
    @test res.centers ≈ [1.5 4.0]
    @test res.totalcost ≈ 0.5
    @test res.converged
end

@testset "singlethread linear separation" begin
    Random.seed!(2020)

    X = rand(3, 100)
    res = kmeans(X, 3; tol = 1e-6, verbose = false)

    @test res.totalcost ≈ 14.16198704459199
    @test res.converged
end


@testset "multithread linear separation" begin
    Random.seed!(2020)

    X = rand(3, 100)
    res = kmeans(X, 3, MultiThread(); tol = 1e-6, verbose = false)

    @test res.totalcost ≈ 14.16198704459199
    @test res.converged
end

end # module
