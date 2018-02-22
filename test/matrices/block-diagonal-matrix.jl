@testset "block-diagonal-matrix.jl" begin
    path1 = tempname()
    path2 = tempname()
    mmax  = 5
    A = DenseBlockDiagonalMatrix(path1, mmax)
    B = DenseBlockDiagonalMatrix(path2, mmax)
    try
        for m = 0:mmax
            A[m] = complex.(randn(5, 5), randn(5, 5))
        end

        @. B = A * A
        for m = 0:mmax
            Am = A[m]
            Bm = B[m]
            @test Bm == Am * Am
        end

        BPJSpec.cache!(A)
        BPJSpec.cache!(B)
        for m = 0:mmax
            Am = A[m]
            Bm = B[m]
            @test Bm == Am * Am
        end

        @. B = A + A
        for m = 0:mmax
            Am = A[m]
            Bm = B[m]
            @test Bm == Am + Am
        end

    finally
        rm(path1, recursive=true)
        rm(path2, recursive=true)
    end
end

