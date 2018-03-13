# Copyright (c) 2015-2017 Michael Eastwood
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

struct HierarchicalStorage <: Mechanism
    path :: String
    hierarchy :: Hierarchy
end
Base.show(io::IO, storage::HierarchicalStorage) = print(io, storage.path)
distribute_write(::HierarchicalStorage) = false
distribute_read(::HierarchicalStorage) = true

# IMPORTANT
# =========
# The HierarchicalStorage mechanism works differently to the other storage mechanisms, which take
# one or two indices that range from 1 to some maximum value. This allows those other mechanisms to
# be generally useful as backends for a variety of matrix types.
#
# For the transfer matrix, however, the user is forced to use the HierarchicalStorage mechanism,
# which is specialized for reducing the storage space required for storing short baselines within
# the transfer matrix. However, in order to make this hierarchical storage work, we need to know the
# value of m relative to lmax, so we need to index with m and β directly.
#
# One consequence of this is that the caching mechanism for AbstractBlockMatrices doesn't currently
# work for TransferMatrices, but this can be fixed by making the caching mechanism slightly more
# general (TODO).

function Base.getindex(storage::HierarchicalStorage, m, β)
    hierarchy = storage.hierarchy

    # load each hierarchical component of the transfer matrix
    blocks = Matrix{Complex128}[]
    dirname  = @sprintf("%04d",      β)
    filename = @sprintf("%04d.jld2", m)
    jldopen(joinpath(storage.path, dirname, filename), mode[r]..., IOStream) do file
        for idx = 1:length(hierarchy.divisions)-1
            lmax = hierarchy.divisions[idx+1]
            lmax ≥ m || continue
            objectname = @sprintf("%04d", lmax)
            push!(blocks, file[objectname])
        end
    end

    # stitch the components together into a single matrix
    output = zeros(Complex128,
                   sum(    size(block, 1) for block in blocks),
                   maximum(size(block, 2) for block in blocks))
    offset = 1
    for block in blocks
        range1 = offset:offset+size(block, 1)-1
        range2 = 1:size(block, 2)
        output_view = @view output[range1, range2]
        copy!(output_view, block)
        offset += size(block, 1)
    end
    output
end

function Base.setindex!(storage::HierarchicalStorage, block, lmax, m, β)
    # There seems to be some insinuation that mmap is causing problems. In particular, occasionally
    # I see objects that should have been written to disk, but are instead all zeroes. This results
    # in an InvalidDataException() when we try to read it again. The following line apparently tells
    # JLD2 not to use mmap, but it's an undocumented interface.
    #
    #     jldopen(file, true, true, false, IOStream)
    #
    # Note also that (true, true, false) corresponds to the "a+" mode.
    dirname    = @sprintf("%04d",      β)
    filename   = @sprintf("%04d.jld2", m)
    objectname = @sprintf("%04d",   lmax)
    isdir(joinpath(storage.path, dirname)) || mkpath(joinpath(storage.path, dirname))
    jldopen(joinpath(storage.path, dirname, filename), mode[a]..., IOStream) do file
        file[objectname] = block
    end
    block
end

doc"""
    struct TransferMatrix <: AbstractBlockMatrix{Matrix{Complex128}, 2}

This type represents the transfer matrix of an interferometer. This matrix effectively describes how
an interferometer responds to the sky, including the antenna primary beam, bandpass, and baseline
distribution.

This matrix is hierarchical in the sense that we save on some computational and storage requirements
by separating long baselines from short baselines.

# Fields

* `storage` contains instructions on how to read the matrix from disk
* `cache` is used if we want to keep the matrix in memory
* `metadata` stores the interferometer's metadata
* `lmax` is the largest value of the $l$ quantum number used by the matrix
* `mmax` is the largest value of the $m$ quantum number used by the matrix
"""
struct TransferMatrix <: AbstractBlockMatrix{Matrix{Complex128}, 2}
    storage  :: HierarchicalStorage
    cache    :: Cache{Matrix{Complex128}}
    metadata :: Metadata
    lmax :: Int
    mmax :: Int
end
metadata_fields(matrix::TransferMatrix) = (matrix.metadata, matrix.lmax, matrix.mmax)
nblocks(::Type{TransferMatrix}, metadata, lmax, mmax) = (mmax+1)*length(metadata.frequencies)
linear_index(matrix::TransferMatrix, m, β) = (marxi.mmax+1)*(β-1) + (m+1)
indices(matrix::TransferMatrix) = ((m, β) for β = 1:length(array.frequencies) for m = 0:array.mmax)

function create(::Type{TransferMatrix}, path::String, metadata::Metadata;
                lmax=maximum(maximum_multipole_moment(metadata))+1, rm=false)
    hierarchy = compute_baseline_hierarchy(metadata, lmax)
    storage   = HierarchicalStorage(path, hierarchy)
    mmax = lmax = maximum(hierarchy.divisions)
    output = construct(TransferMatrix, storage, metadata, lmax, mmax)
    rm && rm_old_blocks!(storage, mmax, length(metadata.frequencies))
    write_metadata(storage, MatrixMetadata(output))
    output
end

function rm_old_blocks!(storage::HierarchicalStorage, mmax, Nfreq)
    for β = 1:Nfreq, m = 0:mmax
        dirname    = @sprintf("%04d",      β)
        filename   = @sprintf("%04d.jld2", m)
        path = joinpath(storage.path, dirname, filename)
        isfile(path) && rm(path)
    end
end

function compute!(transfermatrix::TransferMatrix, beam; progress=false)
    if progress
        println("")
        println("| Starting transfer matrix calculation")
        println("|---------")
        println("| ($(now()))")
        println("")
    end

    workers = categorize_workers()

    if progress
        println(workers)
        println(transfermatrix.storage.hierarchy)
    end

    queue = collect(1:length(transfermatrix.metadata.frequencies))
    if progress
        lck = ReentrantLock()
        prg = Progress(length(queue))
        increment() = (lock(lck); next!(prg); unlock(lck))
    end

    @sync for worker in leaders(workers)
        @async while length(queue) > 0
            β = shift!(queue)
            remotecall_fetch(compute_one_frequency!, worker, transfermatrix, workers, beam, β)
            progress && increment()
        end
    end
end

function compute_one_frequency!(transfermatrix::TransferMatrix, workers, beam, β)
    metadata  = transfermatrix.metadata
    hierarchy = transfermatrix.storage.hierarchy

    my_machine   = chomp(readstring(`hostname`))
    subordinates = copy(workers.dict[my_machine])
    if length(subordinates) > 1
        # make sure this process isn't in the worker pool
        deleteat!(subordinates, subordinates .== myid())
    end

    for idx = 1:length(hierarchy.divisions)-1
        lmax = hierarchy.divisions[idx+1]
        baselines = transfermatrix.metadata.baselines[hierarchy.baselines[idx]]
        blocks = compute_baseline_group_one_frequency!(transfermatrix, subordinates,
                                                       beam, baselines, lmax, β)
        resize!(blocks, 0)
        finalize(blocks)
        gc(); gc() # please please please garbage collect `blocks`
    end
end

function compute_baseline_group_one_frequency!(transfermatrix::TransferMatrix,
                                               subordinates, beam, baselines, lmax, β)
    pool = CachingPool(subordinates)

    # "... but in this world nothing can be said to be certain, except death
    #  and taxes and lmax=mmax"
    #   - Benjamin Franklin, 1789
    mmax = lmax
    ν = transfermatrix.metadata.frequencies[β]
    phase_center = transfermatrix.metadata.phase_center
    beam_map = create_beam_map(beam, transfermatrix.metadata, (lmax+1, 2mmax+1))
    rhat = unit_vectors(beam_map)
    plan = plan_sht(lmax, mmax, size(rhat))

    queue  = collect(1:length(baselines))
    blocks = [zeros(Complex128, two(m)*length(baselines), lmax-m+1) for m = 0:mmax]

    function just_do_it(α)
        real_coeff, imag_coeff = fringe_pattern(baselines[α], phase_center, beam_map, rhat, plan, ν)
    end

    @sync for subordinate in subordinates
        @async while length(queue) > 0
            α = pop!(queue)
            real_coeff, imag_coeff = remotecall_fetch(just_do_it, pool, α)
            fix_scaling!(real_coeff, imag_coeff, ν)
            write_to_blocks!(blocks, real_coeff, imag_coeff, lmax, mmax, α)
        end
    end

    for m = 0:mmax
        transfermatrix.storage[lmax, m, β] = blocks[m+1]
    end
    blocks
end

function fix_scaling!(real_coeff, imag_coeff, ν)
    # Our m-modes are in units of Jy, but our alm are in units of K. Here we apply the scaling
    # factor to the transfer matrix that makes this work with the right units.

    # This is the conversion factor I have been using to convert my alm into units of K. We'll apply
    # the inverse here to the transfer matrix so that this conversion factor is no longer necessary.
    factor = ustrip(uconvert(u"K", u"Jy * c^2/(2*k)"/ν^2))
    real_coeff.matrix ./= factor
    imag_coeff.matrix ./= factor
end

function write_to_blocks!(blocks, real_coeff, imag_coeff, lmax, mmax, α)
    # m = 0
    block = blocks[1]
    for l = 0:lmax
        block[α, l+1] = conj(real_coeff[l, 0]) + 1im*conj(imag_coeff[l, 0])
    end
    # m > 0
    for m = 1:mmax
        block = blocks[m+1]
        α1 = 2α-1 # positive m
        α2 = 2α-0 # negative m
        for l = m:lmax
            block[α1, l-m+1] = conj(real_coeff[l, m]) + 1im*conj(imag_coeff[l, m])
            block[α2, l-m+1] = conj(real_coeff[l, m]) - 1im*conj(imag_coeff[l, m])
        end
    end
end

"Compute the spherical harmonic transform of the fringe pattern for the given baseline."
function fringe_pattern(baseline, phase_center, beam_map, rhat, plan, ν)
    λ = u"c" / ν
    real_fringe, imag_fringe = plane_wave(rhat, baseline, phase_center, λ)
    real_coeff = plan * Map(real_fringe .* beam_map)
    imag_coeff = plan * Map(imag_fringe .* beam_map)
    real_coeff, imag_coeff
end

function plane_wave(rhat, baseline, phase_center, λ)
    real_part = similar(rhat, Float64)
    imag_part = similar(rhat, Float64)
    two_π = 2π
    δϕ = two_π*dot(phase_center, baseline)/λ
    for idx in eachindex(rhat)
        ϕ = uconvert(u"rad", two_π*dot(rhat[idx], baseline)/λ - δϕ)
        real_part[idx] = cos(ϕ)
        imag_part[idx] = sin(ϕ)
    end
    Map(real_part), Map(imag_part)
end

"Compute the unit vector to each point on the sky."
function unit_vectors(map)
    rhat = Matrix{Direction}(size(map))
    for jdx = 1:size(map, 2), idx = 1:size(map, 1)
        rhat[idx, jdx] = index2vector(map, idx, jdx)
    end
    rhat
end

"Create an image of the beam model."
function create_beam_map(f, metadata, size)
    zenith = Direction(metadata.position)
    north  = gram_schmidt(Direction(dir"ITRF", 0, 0, 1), zenith)
    east   = cross(north, zenith)

    map = BPJSpec.Map(zeros(size))
    for jdx = 1:size[2], idx = 1:size[1]
        vec = index2vector(map, idx, jdx)
        x = dot(vec, east)
        y = dot(vec, north)
        z = dot(vec, zenith)
        elevation = asin(clamp(z, -1, 1))
        azimuth   = atan2(x, y)
        map[idx, jdx] = f(azimuth, elevation)
    end
    map
end

"Get the baseline permutation vector for the given value of m."
function baseline_permutation(transfermatrix::TransferMatrix, m)
    hierarchy = transfermatrix.storage.hierarchy
    indices = Int[]
    for idx = 1:length(hierarchy.divisions)-1
        lmax = hierarchy.divisions[idx+1]
        m > lmax && continue
        if m == 0
            append!(indices, hierarchy.baselines[idx])
        else
            for baseline in hierarchy.baselines[idx]
                push!(indices, 2*baseline-1) # positive m
                push!(indices, 2*baseline-0) # negative m
            end
        end
    end
    indices
end
