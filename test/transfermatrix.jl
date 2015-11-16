let
    frame = ReferenceFrame()
    set!(frame,Position(pos"ITRF",q"0.0m",q"0.0deg",q"90.0deg"))
    set!(frame,Epoch(epoch"UTC",Quantity(50237.29,"d")))
    beam = itrf_beam(frame,SineBeam(1.0),45e6)
    for i = 1:length(beam)
        θ,ϕ = LibHealpix.pix2ang_ring(512,i)
        if θ < π/2
            @test abs(beam[i] - cos(θ)) < 1e-5
        else
            @test abs(beam[i]) < 1e-5
        end
    end
end

let Nbase = 10, lmax = 10
    @test BPJSpec.default_size(BPJSpec.TransferMatrixBlock,Nbase,lmax,0) == (10,11)
    @test BPJSpec.default_size(BPJSpec.TransferMatrixBlock,Nbase,lmax,1) == (20,10)
    @test BPJSpec.default_size(BPJSpec.TransferMatrixBlock,Nbase,lmax,2) == (20, 9)

    @test (BPJSpec.TransferMatrixBlock(Nbase,lmax,0,45e6) |> size
                == BPJSpec.default_size(BPJSpec.TransferMatrixBlock,Nbase,lmax,0))
    @test (BPJSpec.TransferMatrixBlock(Nbase,lmax,1,45e6) |> size
                == BPJSpec.default_size(BPJSpec.TransferMatrixBlock,Nbase,lmax,1))
    @test (BPJSpec.TransferMatrixBlock(Nbase,lmax,2,45e6) |> size
                == BPJSpec.default_size(BPJSpec.TransferMatrixBlock,Nbase,lmax,2))
end

let Nbase = 10, lmax = 10, mmax = 10
    blocks = [BPJSpec.TransferMatrixBlock(Nbase,lmax,m,45e6) for m = 0:mmax]
    B = TransferMatrix(blocks)
    @test typeof(B) == TransferMatrix{BPJSpec.one_ν}

    blocks = [BPJSpec.TransferMatrixBlock(Nbase,lmax,3,ν) for ν in linspace(45e6,50e6,5)]
    B = TransferMatrix(blocks)
    @test typeof(B) == TransferMatrix{BPJSpec.one_m}
end

# infinitesimally short baselines should only have nonzero elements when l=m=0
let Nbase = 1, lmax = 3, mmax = 3
    beam = ones(12*512*512) |> HealpixMap
    u = rand(Nbase)*1e-16
    v = rand(Nbase)*1e-16
    w = zeros(Nbase)
    ν = 45e6
    phasecenter = (0,0,1)
    B = gentransfer(beam,u,v,w,ν,phasecenter,lmax=lmax,mmax=mmax)

    for α = 1:Nbase
        @test abs(B[α,0,0]) > 1
    end
    for l = 1:lmax, α = 1:Nbase
        @test abs(B[α,l,0]) < 1e-5 # likely limited by accuracy of spherical harmonic transform
    end
    for m = 1:mmax, l = m:lmax, α = 1:2Nbase
        @test abs(B[α,l,m]) < 1e-5 # likely limited by accuracy of spherical harmonic transform
    end
end

# if we've defined the transfer matrix correctly, we should be able to compute
# visibilities that match those computed directly from TTCal
let Nant = 5, Nfreq = 2, lmax = 100, mmax = 100
    name,ms = createms(Nant,Nfreq)
    beam = HealpixMap(ones(12*512*512))
    u,v,w = itrf_baselines(ms)
    phasecenter = itrf_phasecenter(ms)

    # let's begin with a single source on the north pole
    alm = Alm(Complex128,lmax,mmax)
    for m = 0:mmax, l = m:lmax
        alm[l,m] = BPJSpec.Y(l,m,0.0,0.0) |> conj
    end
    B = gentransfer(beam,u,v,w,ms.ν[1],phasecenter,lmax=lmax,mmax=mmax)
    v = B*alm
    vis = visibilities(v)
    expected = ones(Complex128,size(vis)) # visibilities should always be unity
    @test isapprox(vis,expected,atol=1e-1)

    # note that there are two things likely contributing to the rough
    # tolerance:
    # 1. point sources carry power to large l, which means that by
    #    truncating the spherical harmonic expansion at some lmax,
    #    we are missing some of the flux
    # 2. alm2map and map2alm have some error that we must live with
    #    until I wrap their iterative counterparts
end

#=
# test transfermatrix i/o
let Nbase = 100, lmax = 20, mmax = 20
    filename = tempname()*".jld"
    ν = 45e6

    B1 = [BPJSpec.TransferMatrixBlock(Nbase,lmax,m,ν) for m = 0:mmax] |> TransferMatrix
    for m = 0:mmax
        rand!(B1[m].block)
    end
    save_transfermatrix(filename,B1)

    B2 = load_transfermatrix(filename,ν)
    @test B1 == B2

    # and make sure we can write multiple frequencies to the same file
    B3 = [BPJSpec.TransferMatrixBlock(Nbase,lmax,m,ν+1e6) for m = 0:mmax] |> TransferMatrix
    for m = 0:mmax
        rand!(B3[m].block)
    end
    save_transfermatrix(filename,B3)

    B4 = load_transfermatrix(filename,ν)
    B5 = load_transfermatrix(filename,ν+1e6)
    @test B1 == B4
    @test B3 == B5
end
=#

