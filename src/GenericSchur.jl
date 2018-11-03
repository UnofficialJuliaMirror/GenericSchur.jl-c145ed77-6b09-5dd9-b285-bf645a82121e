module GenericSchur
using LinearAlgebra
using LinearAlgebra: Givens, Rotation
using Printf
import LinearAlgebra: lmul!, mul!, checksquare

# This is the public interface of the package.
# Wrappers like `schur` and `eigvals` should just work.
import LinearAlgebra: schur!, eigvals!, eigvecs

schur!(A::StridedMatrix{T}; kwargs...) where {T} = gschur!(A; kwargs...)

function eigvals!(A::StridedMatrix{T}; kwargs...) where {T}
    S = gschur!(A; wantZ=false, kwargs...)
    S.values
end

# This is probably the best we can do unless LinearAlgebra coöperates
function eigvecs(S::Schur{T}) where {T <: Complex}
    _geigvecs!(S.T,S.Z)
end
############################################################################
# Internal implementation follows


include("util.jl")
include("hessenberg.jl")
include("householder.jl")

function _gschur!(H::HessenbergFactorization{T}, Z=nothing;
                 debug = false,
                 maxiter = 100*size(H, 1), maxinner = 30*size(H, 1), kwargs...
                 ) where {T <: Complex}
    n = size(H, 1)
    istart = 1
    iend = n
    w = Vector{T}(undef, n)
    HH = H.data

    RT = real(T)
    ulp = eps(RT)
    smallnum = safemin(RT) * (n / ulp)
    rzero = zero(RT)
    half = 1 / RT(2)
    threeq = 3 / RT(4)

    # iteration count
    it = 0

    @inbounds while iend >= 1
        istart = 1
        for its=0:maxinner
            it += 1
            if it > maxiter
                throw(ArgumentError("iteration limit $maxiter reached"))
            end

            # Determine if the matrix splits.
            # Find lowest positioned subdiagonal "zero" if any; reset istart
            for _istart in iend - 1:-1:istart
                debug && @printf("Subdiagonal element is: %10.3e%+10.3eim and istart,iend now %6d:%6d\n", reim(HH[_istart+1, _istart])..., istart,iend)
                if abs1(HH[_istart + 1, _istart]) <= smallnum
                    istart = _istart + 1
                    debug && @printf("Split1! Subdiagonal element is: %10.3e%+10.3eim and istart now %6d\n", reim(HH[istart, istart - 1])..., istart)
                    break
                end
                # deflation criterion from Ahues & Tisseur (LAWN 122, 1997)
                tst = abs1(HH[_istart,_istart]) + abs1(HH[_istart+1,_istart+1])
                if tst == 0
                    if (_istart-1 >= 1) tst += abs(real(HH[_istart,_istart-1])) end
                    if (_istart+2 <= n) tst += abs(real(HH[_istart+2,_istart+1])) end
                end
                if abs(real(HH[_istart+1,_istart])) <= ulp*tst
                    ab = max(abs1(HH[_istart+1,_istart]),
                             abs1(HH[_istart,_istart+1]))
                    ba = min(abs1(HH[_istart+1,_istart]),
                             abs1(HH[_istart,_istart+1]))
                    aa = max(abs1(HH[_istart+1,_istart+1]),
                             abs1(HH[_istart,_istart]-HH[_istart+1,_istart+1]))
                    bb = min(abs1(HH[_istart+1,_istart+1]),
                             abs1(HH[_istart,_istart]-HH[_istart+1,_istart+1]))
                    s = aa + ab
                    if ba * (ab / s) <= max(smallnum, ulp * (bb * (aa / s)))
                        istart = _istart + 1
                        debug && @printf("Split2! Subdiagonal element is: %10.3e%+10.3eim and istart now %6d\n", reim(HH[istart, istart - 1])..., istart)
                        break
                    end
                end
                # istart = 1
            end # check for split

            if istart > 1
                # clean up
                HH[istart, istart-1] = zero(T)
            end

            # if block size is one we deflate
            if istart >= iend
                debug && @printf("Bottom deflation! Block size is one. New iend is %6d\n", iend - 1)
                iend -= 1
                break
            end

            # select shift
            # logic adapted from LAPACK zlahqr
            if its % 30 == 10
                s = threeq * abs(real(HH[istart+1,istart]))
                t = s + HH[istart,istart]
            elseif its % 30 == 20
                s = threeq * abs(real(HH[iend,iend-1]))
                t = s + HH[iend,iend]
            else
                t = HH[iend,iend]
                u = sqrt(HH[iend-1,iend]) * sqrt(HH[iend,iend-1])
                s = abs1(u)
                if s ≠ rzero
                    x = half * (HH[iend-1,iend-1] - t)
                    sx = abs1(x)
                    s = max(s, abs1(x))
                    y = s * sqrt( (x/s)^2 + (u/s)^2)
                    if sx > rzero
                        if real(x / sx) * real(y) + imag(x / sx) * imag(y) < rzero
                            y = -y
                        end
                    end
                    t -= u * (u / (x+y))
                end
            end # shift selection

            # run a QR iteration
            debug && @printf("block start is: %6d, block end is: %6d, t: %10.3e%+10.3eim\n", istart, iend, reim(t)...)
            # zlahqr only has single-shift
            singleShiftQR!(HH, Z, t, istart, iend)

        end # inner loop
    end # outer loop
    w = diag(HH)
    return Schur(triu(HH), Z === nothing ? Matrix{T}(undef,0,0) : Z, w)
end

"""
gschur(A::StridedMatrix) -> F::Schur

Computes the Schur factorization of matrix `A` using a generic implementation.
See `LinearAlgebra.schur` for usage.
"""
gschur(A::StridedMatrix{T}; kwargs...) where {T} = gschur!(Matrix(A); kwargs...)

"""
gschur!(A::StridedMatrix) -> F::Schur

Destructive version of `gschur` (q.v.).
"""
function gschur!(A::StridedMatrix{T}; wantZ::Bool=true, scale::Bool=true,
                 permute::Bool=false, kwargs...) where T <: Complex
    n = checksquare(A)
    # FIXME: some LinearAlgebra wrappers force default permute=true
    # so we must silently ignore it here.
#    permute &&
#        throw(ArgumentError("permute option is not available for this method"))
    if scale
        scaleA, cscale, anrm = _scale!(A)
    else
        scaleA = false
    end
    H = _hessenberg!(A)
    if wantZ
        τ = H.τ # Householder reflectors w/ scales
        Z = Matrix{T}(I, n, n)
        for j=n-1:-1:1
            lmul!(τ[j], view(Z, j+1:n, j:n))
            Z[1:j-1,j] .= 0
        end
        S = _gschur!(H, Z; kwargs...)
    else
        S = _gschur!(H; kwargs...)
    end
    if scaleA
        safescale!(S.T, cscale, anrm)
        S.values .= diag(S.T, 0)
    end
    S
end

# Note: zlahqr exploits the fact that some terms are real to reduce
# arithmetic load.  Does that also work with Givens version?
# Is it worth the trouble?

function singleShiftQR!(HH::StridedMatrix{T}, Z, shift::Number, istart::Integer, iend::Integer) where {T <: Complex}
    m = size(HH, 1)
    ulp = eps(real(eltype(HH)))

    # look for two consecutive small subdiagonals
    istart1 = -1
    h11s = zero(eltype(HH))
    h21 = zero(real(eltype(HH)))
    for mm = iend-1:-1:istart+1
        # determine the effect of starting the single-shift Francis
        # iteration at row mm: see if this would make HH[mm,mm-1] tiny.
        h11 = HH[mm,mm]
        h22 = HH[mm+1,mm+1]
        h11s = h11 - shift
#        h21 = real(HH[mm+1,mm]) # for reflector
        h21 = HH[mm+1,mm]
        s = abs1(h11s) + abs(h21)
        h11s /= s
        h21 /= s
        h10 = real(HH[mm,mm-1])
        if abs(h10)*abs(h21) <= ulp *
            (abs1(h11s)*(abs1(h11)+abs1(h22)))
            istart1 = mm
            break
        end
    end
    if istart1 < 1
        istart1 = istart
        h11 = HH[istart,istart]
        h22 = HH[istart+1,istart+1]
        h11s = h11 - shift
        # h21 = real(HH[istart+1,istart]) # for reflector
        h21 = HH[istart+1,istart]
        s = abs1(h11s) + abs(h21)
        h11s /= s
        h21 /= s
    end

    if m > istart1 + 1
        Htmp = HH[istart1 + 2, istart1]
        HH[istart1 + 2, istart1] = 0
    end

    # create a bulge
    G, _ = givens(h11s, h21, istart1, istart1 + 1)
    lmul!(G, view(HH, :, istart1:m))
    rmul!(view(HH, 1:min(istart1 + 2, iend), :), G')
    Z === nothing || rmul!(Z, G')
    # do we need this? LAPACK uses Householder so some work would be needed
    # if istart1 > istart
        # if two consecutive small subdiagonals were found, scale
        # so HH[istart1,istart1-1] remains real.
    # end

    # chase the bulge down
    for i = istart1:iend - 2
        # i is K-1, istart is M
        G, _ = givens(HH[i + 1, i], HH[i + 2, i], i + 1, i + 2)
        lmul!(G, view(HH, :, i:m))
        HH[i + 2, i] = Htmp
        if i < iend - 2
            Htmp = HH[i + 3, i + 1]
            HH[i + 3, i + 1] = 0
        end
        rmul!(view(HH, 1:min(i + 3, iend), :), G')
        Z === nothing || rmul!(Z, G')
    end
    return HH
end

function _gschur!(H::HessenbergFactorization{T}, Z=nothing; tol = eps(real(T)), debug = false, shiftmethod = :Francis, maxiter = 100*size(H, 1), kwargs...) where {T <: Real}
    n = size(H, 1)
    istart = 1
    iend = n
    HH = H.data
    τ = Rotation(Givens{T}[])

    # iteration count
    i = 0

    @inbounds while true
        i += 1
        if i > maxiter
            throw(ArgumentError("iteration limit $maxiter reached"))
        end

        # Determine if the matrix splits. Find lowest positioned subdiagonal "zero"
        for _istart in iend - 1:-1:1
            if abs(HH[_istart + 1, _istart]) < tol*(abs(HH[_istart, _istart]) + abs(HH[_istart + 1, _istart + 1]))
                    istart = _istart + 1
                if T <: Real
                    debug && @printf("Split! Subdiagonal element is: %10.3e and istart now %6d\n", HH[istart, istart - 1], istart)
                else
                    debug && @printf("Split! Subdiagonal element is: %10.3e%+10.3eim and istart now %6d\n", reim(HH[istart, istart - 1])..., istart)
                end
                break
            elseif _istart > 1 && abs(HH[_istart, _istart - 1]) < tol*(abs(HH[_istart - 1, _istart - 1]) + abs(HH[_istart, _istart]))
                if T <: Real
                    debug && @printf("Split! Next subdiagonal element is: %10.3e and istart now %6d\n", HH[_istart, _istart - 1], _istart)
                else
                    debug && @printf("Split! Next subdiagonal element is: %10.3e%+10.3eim and istart now %6d\n", reim(HH[_istart, _istart - 1])..., _istart)
                end
                istart = _istart
                break
            end
            istart = 1
        end

        # if block size is one we deflate
        if istart >= iend
            debug && @printf("Bottom deflation! Block size is one. New iend is %6d\n", iend - 1)
            iend -= 1

        # and the same for a 2x2 block
        elseif istart + 1 == iend
            debug && @printf("Bottom deflation! Block size is two. New iend is %6d\n", iend - 2)

            iend -= 2

        # run a QR iteration
        # shift method is specified with shiftmethod kw argument
        else
            Hmm = HH[iend, iend]
            Hm1m1 = HH[iend - 1, iend - 1]
            d = Hm1m1*Hmm - HH[iend, iend - 1]*HH[iend - 1, iend]
            t = Hm1m1 + Hmm
            t = iszero(t) ? eps(real(one(t))) : t # introduce a small pertubation for zero shifts
            if T <: Real
                debug && @printf("block start is: %6d, block end is: %6d, d: %10.3e, t: %10.3e\n", istart, iend, d, t)
            else
                debug && @printf("block start is: %6d, block end is: %6d, d: %10.3e%+10.3eim, t: %10.3e%+10.3eim\n", istart, iend, reim(d)..., reim(t)...)
            end

            if shiftmethod == :Francis
                # Run a bulge chase
                if iszero(i % 10)
                    # Vary the shift strategy to avoid dead locks
                    # We use a Wilkinson-like shift as suggested in "Sandia technical report 96-0913J: How the QR algorithm fails to converge and how fix it".

                    if T <: Real
                        debug && @printf("Wilkinson-like shift! Subdiagonal is: %10.3e, last subdiagonal is: %10.3e\n", HH[iend, iend - 1], HH[iend - 1, iend - 2])
                    else
                        debug && @printf("Wilkinson-like shift! Subdiagonal is: %10.3e%+10.3eim, last subdiagonal is: %10.3e%+10.3eim\n", reim(HH[iend, iend - 1])..., reim(HH[iend - 1, iend - 2])...)
                    end
                    _d = t*t - 4d

                    if _d isa Real && _d >= 0
                        # real eigenvalues
                        a = t/2
                        b = sqrt(_d)/2
                        s = a > Hmm ? a - b : a + b
                    else
                        # complex case
                        s = t/2
                    end
                    singleShiftQR!(HH, τ, Z, s, istart, iend)
                else
                    # most of the time use Francis double shifts
                    if T <: Real
                        debug && @printf("Francis double shift! Subdiagonal is: %10.3e, last subdiagonal is: %10.3e\n", HH[iend, iend - 1], HH[iend - 1, iend - 2])
                    else
                        debug && @printf("Francis double shift! Subdiagonal is: %10.3e%+10.3eim, last subdiagonal is: %10.3e%+10.3eim\n", reim(HH[iend, iend - 1])..., reim(HH[iend - 1, iend - 2])...)
                    end
                    doubleShiftQR!(HH, τ, Z, t, d, istart, iend)
                end
            elseif shiftmethod == :Rayleigh
                if T <: Real
                    debug && @printf("Single shift with Rayleigh shift! Subdiagonal is: %10.3e\n", HH[iend, iend - 1])
                else
                    debug && @printf("Single shift with Rayleigh shift! Subdiagonal is: %10.3e%+10.3eim\n", reim(HH[iend, iend - 1])...)
                end

                # Run a bulge chase
                singleShiftQR!(HH, τ, Z, Hmm, istart, iend)
            else
                throw(ArgumentError("only support supported shift methods are :Francis (default) and :Rayleigh. You supplied $shiftmethod"))
            end
        end
        if iend <= 2 break end
    end

    TT = triu(HH,-1)
    v = _geigvals!(TT)
    return Schur{T,typeof(TT)}(TT, Z === nothing ? similar(TT,0,0) : Z, v)
end

function gschur!(A::StridedMatrix{T}; wantZ::Bool=true, scale::Bool=true,
                 permute::Bool=false, kwargs...) where {T <: Real}
    n = checksquare(A)
    # permute &&
    #    throw(ArgumentError("permute option is not available for this method"))
    if scale
        scaleA, cscale, anrm = _scale!(A)
    else
        scaleA = false
    end
    H = _hessenberg!(A)
    if wantZ
        Z = Matrix{T}(I, n, n)
        for j=n-1:-1:1
            lmul!(H.τ[j], view(Z, j+1:n, j:n))
            Z[1:j-1,j] .= 0
        end
        S = _gschur!(H, Z; kwargs...)
    else
        S = _gschur!(H; kwargs...)
    end
    if scaleA
        safescale!(S.T, cscale, anrm)
        safescale!(S.values, cscale, anrm)
    end
    S
end

function singleShiftQR!(HH::StridedMatrix{T}, τ::Rotation, Z, shift::Number, istart::Integer, iend::Integer) where {T <: Real}
    m = size(HH, 1)
    H11 = HH[istart, istart]
    H21 = HH[istart + 1, istart]
    if m > istart + 1
        Htmp = HH[istart + 2, istart]
        HH[istart + 2, istart] = 0
    end
    G, _ = givens(H11 - shift, H21, istart, istart + 1)
    lmul!(G, view(HH, :, istart:m))
    rmul!(view(HH, 1:min(istart + 2, iend), :), G')
    lmul!(G, τ)
    Z === nothing || rmul!(Z,G')
    for i = istart:iend - 2
        G, _ = givens(HH[i + 1, i], HH[i + 2, i], i + 1, i + 2)
        lmul!(G, view(HH, :, i:m))
        HH[i + 2, i] = Htmp
        if i < iend - 2
            Htmp = HH[i + 3, i + 1]
            HH[i + 3, i + 1] = 0
        end
        rmul!(view(HH, 1:min(i + 3, iend), :), G')
        lmul!(G, τ) # *RAS* AN dropped this
        Z === nothing || rmul!(Z,G')
    end
    return HH
end

function doubleShiftQR!(HH::StridedMatrix{T}, τ::Rotation, Z, shiftTrace::Number, shiftDeterminant::Number, istart::Integer, iend::Integer) where {T <: Real}
    m = size(HH, 1)
    H11 = HH[istart, istart]
    H21 = HH[istart + 1, istart]
    Htmp11 = HH[istart + 2, istart]
    HH[istart + 2, istart] = 0
    if istart + 3 <= m
        Htmp21 = HH[istart + 3, istart]
        HH[istart + 3, istart] = 0
        Htmp22 = HH[istart + 3, istart + 1]
        HH[istart + 3, istart + 1] = 0
    else
        # values doen't matter in this case but variables should be initialized
        Htmp21 = Htmp22 = Htmp11
    end
    G1, r = givens(H11*H11 + HH[istart, istart + 1]*H21 - shiftTrace*H11 + shiftDeterminant, H21*(H11 + HH[istart + 1, istart + 1] - shiftTrace), istart, istart + 1)
    G2, _ = givens(r, H21*HH[istart + 2, istart + 1], istart, istart + 2)
    vHH = view(HH, :, istart:m)
    lmul!(G1, vHH)
    lmul!(G2, vHH)
    vHH = view(HH, 1:min(istart + 3, m), :)
    rmul!(vHH, G1')
    rmul!(vHH, G2')
    lmul!(G1, τ)
    lmul!(G2, τ)
    Z === nothing || rmul!(Z,G1')
    Z === nothing || rmul!(Z,G2')
    for i = istart:iend - 2
        for j = 1:2
            if i + j + 1 > iend break end
            # G, _ = givens(H.H,i+1,i+j+1,i)
            G, _ = givens(HH[i + 1, i], HH[i + j + 1, i], i + 1, i + j + 1)
            lmul!(G, view(HH, :, i:m))
            HH[i + j + 1, i] = Htmp11
            Htmp11 = Htmp21
            # if i + j + 2 <= iend
                # Htmp21 = HH[i + j + 2, i + 1]
                # HH[i + j + 2, i + 1] = 0
            # end
            if i + 4 <= iend
                Htmp22 = HH[i + 4, i + j]
                HH[i + 4, i + j] = 0
            end
            rmul!(view(HH, 1:min(i + j + 2, iend), :), G')
            lmul!(G, τ) # *RAS* AN dropped this
            Z === nothing || rmul!(Z,G')
        end
    end
    return HH
end

# get eigenvalues from a quasitriangular Schur factor
function _geigvals!(HH::StridedMatrix{T}; tol = eps(T)) where {T <: Real}
# TODO: (optionally) compute the rotations needed for standard form,
# apply them to HH, and zero out the negligible parts of HH.
# Also return the rotations for application to Z. cf. LAPACK::dlanv2.
    n = size(HH, 1)
    vals = Vector{complex(T)}(undef, n)
    i = 1
    while i < n
        Hii = HH[i, i]
        Hi1i1 = HH[i + 1, i + 1]
        rtest = tol*(abs(Hi1i1) + abs(Hii))
        if abs(HH[i + 1, i]) < rtest
            vals[i] = Hii
            i += 1
        else
            d = Hii*Hi1i1 - HH[i, i + 1]*HH[i + 1, i]
            t = Hii + Hi1i1
            x = 0.5*t
            y = sqrt(complex(x*x - d))
            vals[i] = x + y
            vals[i + 1] = x - y
            i += 2
        end
    end
    if i == n
        vals[i] = HH[n, n]
    end
    return vals
end

# Compute right eigenvectors of a complex upper triangular matrix TT.
# If Z is nontrivial, multiply by it to get eigenvectors of Z*TT*Z'.
# based on LAPACK::ztrevc
function _geigvecs!(TT::StridedMatrix{T},
                    Z::StridedMatrix{T}=Matrix{T}(undef,0,0)
                    ) where {T <: Complex}
    n = size(TT,1)
    RT = real(T)
    ulp = eps(RT)
    smallnum = safemin(RT) * (n / ulp)
    vectors = Matrix{T}(undef,n,n)
    v = zeros(T,n)

    # save diagonal since we modify it to avoid copies
    tdiag = diag(TT)

    # We use the 1-norms of the strictly upper part of TT columns
    # to avoid overflow
    tnorms = zeros(RT,n)
    @inbounds for j=2:n
        for i=1:j-1
            tnorms[j] += abs(TT[i,j])
        end
    end

    for ki=n:-1:1
        smin = max(ulp * abs1(TT[ki,ki]), smallnum)
        #
        # (T[1:k,1:k]-λI) x = b
        # where k=kᵢ-1

        v[1] = one(T) # for ki=1
        @inbounds for k=1:ki-1
            v[k] = -TT[k,ki]
        end
        @inbounds for k=1:ki-1
            TT[k,k] -= TT[ki,ki]
            (abs1(TT[k,k]) < smin) && (TT[k,k] = smin)
        end
        if ki > 1
            vscale = _usolve!(TT,ki-1,v,tnorms)
            v[ki] = vscale
        else
            vscale = one(RT)
        end
        if size(Z,1) > 0
            # This is done here to avoid allocating a work matrix
            # and to exploit the subspace property to reduce work.
            # Using a work matrix would allow for level-3 ops (cf. ztrevc3).
            @inbounds for j=1:n
                vectors[j,ki] = vscale * Z[j,ki]
                for i=1:ki-1
                    vectors[j,ki] += Z[j,i] * v[i]
                end
            end
        else
            @inbounds for j=1:ki
                vectors[j,ki] = v[j]
            end
            vectors[ki+1:n,ki] .= zero(T)
        end

        # normalize
        t0 = abs1(vectors[1,ki])
        @inbounds for i=2:n; t0 = max(t0, abs1(vectors[i,ki])); end
        remax = one(RT) / t0
        @inbounds for i=1:n; vectors[i,ki] *= remax; end

        # restore diagonal
        @inbounds for k=1:ki-1
            TT[k,k] = tdiag[k]
        end
    end

    vectors
end

end # module