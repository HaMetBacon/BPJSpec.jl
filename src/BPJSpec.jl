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

#__precompile__()

module BPJSpec

export HierarchicalTransferMatrix
export FileBackedTransferMatrix
export MModes

using CasaCore.Measures
using FastTransforms
using FileIO, JLD2
using ProgressMeter
using StaticArrays
using Unitful, UnitfulAstro

two(m) = ifelse(m > 0, 2, 1)

include("parallel.jl")
include("cosmology.jl")
include("spherical-harmonics.jl")
include("metadata.jl")

abstract type SkyComponent end
include("sky/foregrounds.jl")
include("sky/signal.jl")
include("sky/noise.jl")

abstract type BlockMatrix end
include("matrices/block-diagonal-matrix.jl")
include("matrices/spectral-block-diagonal-matrix.jl")
include("matrices/angular-covariance-matrix.jl")
include("matrices/transfer-matrix.jl")

include("hierarchy.jl")
include("m-modes.jl")
include("compress.jl")
include("imaging.jl")

#export GriddedVisibilities, grid!
#export MModes, TransferMatrix
#export tikhonov
#
#using CasaCore.Measures
#using CasaCore.Tables
#using LibHealpix
#using TTCal
#
#importall Base.Operators
#import Cosmology
#import GSL
#import LibHealpix: Alm, lmax, mmax
#import TTCal: Nfreq

#include("special.jl")     # special functions
#include("physics.jl")     # physical constants and cosmology
#include("parallel.jl")    # tools for parallel processing
#include("definitions.jl") # defines all the types
#include("visibilities.jl")
#include("mmodes.jl")
#include("transfermatrix.jl")
#include("alm.jl")

##include("noise.jl")
#include("sky.jl")

end

