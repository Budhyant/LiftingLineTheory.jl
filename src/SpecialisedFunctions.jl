#
# SpecialisedFunctions.jl
#
# The dirty mathematical underbelly pinning this whole mess together.
#
# Copyright HJA Bird 2019-2020
#
#============================================================================#

import SpecialFunctions
import FastGaussQuadrature

#= Aerodynamics functions --------------------------------------------------=#
# theodorsen_fn in TheodorsenSimple.jl

function sears_fn(k :: Real)
    @assert(k > 0)
    ret = (theodorsen_fn(k) * (
        SpecialFunctions.besselj0(k) - im * SpecialFunctions.besselj1(k)) +
        im * SpecialFunctions.besselj1(k))
    return ret
end

"""
Generate a Wagner function of using a variable number of terms.

A sum of a_i * exp(b_i * s) terms can be used to approximate Wagner's function.
This is done by taking matching the fourier transform of the above with
Theodorsen's function.

The method currently used is very sensitive to its arguments and sometimes 
produces complete garbage.
"""
function create_wagner_fn(num_terms :: Int, k_max :: Real)
    @assert(num_terms > 0)
    I = num_terms
    lim_k_to_inf = 0.5  # Limit as k->infinity for theodorsen_fn
    lim_k_to_zero = 1   # for theodorsen fn.

    ai = Vector{Float64}(undef, I)
    bi = Vector{Float64}(undef, I)
    bi[1] = 0       # Required to satisfy k->0 limit
    ai[1] = lim_k_to_zero
    # Arbitrarily set
    bi[2:end] = - collect(1:I-1) * k_max / (I - 1)
    # Frequency collocation points - spread over the curve created on complex 
    # plane
    kn = collect( i / (2 * sqrt(I-2)) for i = 1 : I-2)
    mat_inp = [(b, k) for k in kn, b in bi[2:end]]
    matrix = Matrix{Float64}(undef, I-1, I-1)
    matrix[1:I-2,:] = map(
        x -> x[2]^2 * x[2] / (x[1]^2 + x[2]^2),
        mat_inp)
    matrix[end,:] .= 1
    rhs_vec = vcat(imag.(theodorsen_fn.(kn)), lim_k_to_inf) .- lim_k_to_zero
    ai[2:end] = matrix \ rhs_vec
    function wagner_fn(s :: Real)
        if s >= 0
            return mapreduce(
                x -> x[1] * exp(x[2] * s),
                +,
                zip(ai, bi) )
        else
            return 0
        end
    end
    println("Ai = \t", ai)
    println("Bi = \t", bi)
    return wagner_fn
end

"""
R.T. Jones' approximation of Wagner's function.

Argument of s is normalised. For example s = U * t / b where 
U is free stream vel, t is time since the step change and b is the semichord
of the wing section.
"""
function wagner_fn(s :: Real)
    return 1 - 0.165 * exp(-0.0455*s) - 0.335 * exp(-0.0455*s)
end

#= Mappings from Real->Real ------------------------------------------------=#
function linear_remap(  # Checked. GOOD.
    pointin :: Number,   weightin :: Number,
    old_a :: Number,     old_b :: Number,
    new_a :: Number,     new_b :: Number )

    dorig = (pointin - old_a) / (old_b - old_a)
    p_new = new_a + dorig * (new_b - new_a)
    w_new = ((new_b - new_a) / (old_b - old_a)) * weightin
    return p_new, w_new
end

function linear_remap(  # GOOD.
    pointin :: Vector{<:Number},   weightin :: Vector{<:Number},
    old_a :: Number,     old_b :: Number,
    new_a :: Number,     new_b :: Number )
    @assert(length(pointin)==length(weightin))
    pout = deepcopy(pointin)
    wout = deepcopy(weightin)
    for i = 1 : length(pointin)
        pout[i], wout[i] = linear_remap(pointin[i], weightin[i], 
            old_a, old_b, new_a, new_b)
    end
    return pout, wout
end

# Remap to remove weak singularities.
function telles_quadratic_remap(
    pointin :: Number,   weightin :: Number,
    lim_a :: Number,     lim_b :: Number,
    singularity_pos :: Number)

    @assert((singularity_pos==lim_a) || (singularity_pos==lim_b),
        "Singularity position must be equal to one of the limits")
    p, w = linear_remap(pointin, weightin, lim_a, lim_b, -1, 1)
    sp = singularity_pos
    tp = (1 - p^2)*(sp + sqrt(sp^2 - 1)) / 2 + p
    tw = (-p * (sp + sqrt(sp^2 - 1)) + 1) * w
    p, w = linear_remap(tp, tw, -1, 1, lim_a, lim_b)
    return p, w
end

function telles_quadratic_remap(
    pointin :: Vector{<:Number},   weightin :: Vector{<:Number},
    lim_a :: Number,     lim_b :: Number,
    singularity_pos :: Number )
    @assert(length(pointin)==length(weightin))
    pout = deepcopy(pointin)
    wout = deepcopy(weightin)
    for i = 1 : length(pointin)
        pout[i], wout[i] = telles_quadratic_remap(pointin[i], weightin[i], 
        lim_a, lim_b, singularity_pos)
    end
    return pout, wout
end


#= Double exponential remaps for oscillatory integrands --------------------=#
# Sad thing is, it doesn't work.

# The Phi function
function de_remap_semi_inf_osc_rmp_dn(t::Float64, alpha, beta)
    # See notes #7 pg 55
    t1d = exp(-2*t - alpha * (1-exp(-t)) - beta * (exp(t)-1))
    return t1d
end

function de_remap_semi_inf_osc_rmp_dn_deriv(t::Float64, alpha, beta)
    t1 = exp(-2*t - alpha * (1-exp(-t)) - beta * (exp(t)-1))
    t2 = -2 - alpha * exp(-t) - beta * exp(t)
    return t1 * t2
end

function de_remap_semi_inf_osc_deriv(t::Float64, alpha, beta)
    if t != 0
        d = de_remap_semi_inf_osc_rmp_dn(t, alpha, beta)
        dd = de_remap_semi_inf_osc_rmp_dn_deriv(t, alpha, beta)
        t1 = 1/(1-d)
        t2 = t * dd / (1-d^2)
        term = t1 + t2
    else
        a = alpha
        b = beta
        tn = 4 + a^2 + 3*b + b^2 + a * (5 + 2 * b)
        td = 2 * (2 + a + b)^2
        term = tn / td
    end
    @assert(isfinite(term))
    return term
end

function de_remap_semi_inf_osc_int_sin(
    non_oscl_part::Function, omega::Number)

    m = 16
    h = pi / m
    n_m = 10
    n_p = 10
    ns = collect(-n_m:n_p)

    beta = 1/4
    alpha = beta / sqrt(1 + m * log(1 + m)/ (4*pi))
    @assert(0 <= alpha <= beta <= 1)
    println("alpha, beta = ", alpha, ", ", beta)

    phi_dn = x->de_remap_semi_inf_osc_rmp_dn(x, alpha, beta)
    phip = x->de_remap_semi_inf_osc_deriv(x, alpha, beta)
    
    phi_dns = map(n->phi_dn(n * h), ns)
    println("dn = ", phi_dns, "\n")
    @assert(all(isfinite.(phi_dns)))

    An = map(inp->m*h * inp[1] / (1 - inp[2]), zip(ns, phi_dns))
    An[n_m + 1] = m / (2 + alpha + beta) # Where t is zero.
    println("An = ", An, "\n")
    @assert(all(isfinite.(An)))
#=
    Bn = map(
        inp->phip(inp[1] * h) * (-1)^inp[1] * sin(inp[2] * inp[3]), 
        zip(ns, An, phi_dns))=#
    Bn = map(
        inp->phip(inp[1] * h) * sin(inp[2]), 
        zip(ns, An, phi_dns))
    println("Bn = ", Bn, "\n")
    @assert(all(isfinite.(Bn)))

    terms = non_oscl_part.(An ./ omega) .* Bn ./ omega
    if !(terms[n_m + 1] == terms[n_m + 1])
        terms[n_m + 1] = 1
    end

    plot(An./ omega, terms, marker="*")
    println("Terms ", terms, "\n")
    int = pi * sum(terms)
    return int
end

#= Filon Quadrature --------------------------------------------------------=#
# Quadrature for oscillatory problems.

# For functions of the form integrate( f(x) * exp(i omega x), x, a, b)
function filon_quadrature_exp(
    non_oscl::Function, omega::Real, a::Real, b::Real; n=-1, finite=true)
    realpart = filon_quadrature_cos(non_oscl, omega, a, b; n=n, finite=finite)
    imagpart = filon_quadrature_sin(non_oscl, omega, a, b; n=n, finite=finite)
    return realpart + im * imagpart
end

function filon_quadrature_sin(
    non_oscl::Function, omega::Real, a::Real, b::Real; n=-1, finite=true)
    @assert(b > a)
    @assert(isfinite(omega))
    @assert(hasmethod(non_oscl, (Float64,)))

    # We can reuse everything for cos by shifting by pi/2
    f = x->non_oscl(x + pi / (2*omega))
    na = a - pi/(2*omega)
    nb = b - pi/(2*omega)
    return filon_quadrature_cos(f, omega, na, nb; n=n, finite=finite)
end

function filon_quadrature_cos(
    non_oscl::Function, omega::Real, a::Real, b::Real; 
    n=-1, finite=true)
    @assert(b > a)
    @assert(isfinite(omega))
    @assert(hasmethod(non_oscl, (Float64,)))

    if n==-1
        if isfinite(a) && isfinite(b)
            return filon_quadrature_finite_adaptive_cos(non_oscl, omega, a, b;finite=finite)[1]
        end
        
        if isfinite(a) && b == Inf
            return filon_quadrature_semiinf_adaptive_cos(non_oscl, omega, a;finite=finite)
        end

        if isfinite(b) && a == -Inf
            f = x->non_oscl(-x)
            return filon_quadrature_semiinf_adaptive_cos(f, omega, -b;finite=finite)
        end
    end
    @assert(false, "Not done this bit yet!")
end

# Assume integrating in [a, inf]
function filon_quadrature_semiinf_adaptive_cos(
    non_oscl::Function, omega::Real, a::Real; 
    tol=1e-6, maxsegs=1000, finite=true)

    # We break the integrand into intervals and adaptively integrate until we
    # appear to have converged
    @assert(omega >= 0)
    T = 2 * pi / omega
    segment = T==Inf ? 1 : 2*T
    sum = 0
    ll = a
    ul = a+segment
    sum += filon_quadrature_finite_adaptive_cos(
        non_oscl, omega, ll, ul; tol=tol/5)[1]
    sw = segment
    n = 0
    while true
        n += 1
        ll = ul
        ul = ll + segment
        int, refinement = filon_quadrature_finite_adaptive_cos(
            non_oscl, omega, ll, ul; tol=tol/5)
        if abs(int / sum) < tol
            break   # THIS IS A REALLY TERRIBLE CONVERGENCE CRITERIA!
        end
        if finite && !isfinite(int)
            error("Integrand was not finite in [", ll, ", ", ul, "].")
            break
        end
        if refinement > 4
            segment /= 2
        end
        if refinement < 3
            segment *= 2
        end
        sum += int
        sw += segment
        if n > maxsegs
            break
        end
    end
    return sum
end

function filon_quadrature_finite_adaptive_cos(
    non_oscl::Function, omega::Real, a::Real, b::Real; 
    tol=1e-6, itermax=8, finite=true)

    # x1s are fine, x2 are coarse
    n = 32+1
    h1 = (b-a)/(n-1)
    h2 = 2*h1
    x1 = collect(range(a, stop=b, length=n))
    x2 = x1[1:2:end]
    f1 = non_oscl.(x1)
    f2 = f1[1:2:end]
    r2 = filon_eval_finite_cos(x2, f2, omega, h2)
    r1 = r2 # Just to get the correct type.
    iter = 0
    while true
        iter += 1
        r1 = filon_eval_finite_cos(x1, f1, omega, h1)
        if !isfinite(r1)
            break
        end
        rerr = abs(r1 - r2) / abs(r1)
        if rerr*2 < tol
            break
        end
        if iter > itermax
            break
        end
        n = (n-1)*2 + 1
        h1 = (b-a)/(n-1)
        h2 = 2*h1
        x2 = x1
        if abs(b - a)/abs((b+a)/2) < 1e-10
            break # We can't reliably generate a range...
        end
        x1 = collect(range(a, stop=b, length=n))
        f2 = f1
        f1 = zeros(n)
        f1[1:2:end] = f2
        f1[2:2:end] = non_oscl.(x1[2:2:end])
        r2 = r1
    end
    return r1, iter
end

function filon_eval_finite_cos(
    xs::Vector{<:Number}, fs::Vector{<:Number}, omega, h)

    @assert(round((xs[end]-xs[1])/h)+1 == length(xs))
    @assert(length(xs) == length(fs))
    @assert(length(xs)%2 == 1)
    @assert(h >= 0)

    oh = omega * h
    alpha = 1/oh + sin(2*oh)/(2*oh^2) - 2*sin(oh)^2/oh^3
    beta = 2 * ((1+cos(oh)^2)/oh^2 - sin(2*oh)/oh^3)
    gamma = 4 * (sin(oh) / oh^3 - cos(oh) / oh^2)
    c2n = sum(fs[1:2:end] .* cos.(omega .* xs[1:2:end])) - (
        fs[end]*cos(omega*xs[end]) + fs[1]*cos(omega*xs[1]))/2
    c2nm1 = sum(fs[2:2:end] .* cos.(omega * xs[2:2:end]))

    res = h * (alpha * (fs[end] * sin(omega * xs[end]) - fs[1] * sin(omega * xs[1]))
        + beta * c2n + gamma * c2nm1)# + 2 *  omega * h^4 * sp / 45)

    return res
end

#= Newton-Coats ------------------------------------------------------------=#
# It might not be convergent, (see Golub or Trevethan or something),
# but it does work.

function trapezium_quadrature_adaptive(fn::Function, a::Real, b::Real; 
    tol=1e-6, itermax=10)
    @assert(a < b)
    @assert(hasmethod(fn, (Float64,)))
    # x1s are fine, x2 are coarse
    n = 32+1
    h1 = (b-a)/(n-1)
    h2 = 2*h1
    x1 = collect(range(a, stop=b, length=n))
    x2 = x1[1:2:end]
    f1 = fn.(x1)
    f2 = f1[1:2:end]
    r2 = trapezium_eval(x2, f2, h2)
    r1 = r2 # Just to get the correct type.
    iter = 0
    while true
        iter += 1
        r1 = trapezium_eval(x1, f1, h1)
        rerr = abs(r1 - r2) / abs(r1)
        if rerr*2 < tol
            break
        end
        if iter > itermax
            break
        end
        n = (n-1)*2 + 1
        h1 = (b-a)/(n-1)
        h2 = 2*h1
        x2 = x1
        x1 = collect(range(a, stop=b, length=n))
        f2 = f1
        f1 = zeros(n)
        f1[1:2:end] = f2
        f1[2:2:end] = fn.(x1[2:2:end])
        r2 = r1
    end
    return r1
end

function trapezium_eval(
    xs::Vector{<:Number}, fs::Vector{<:Number}, h)

    @assert(round((xs[end]-xs[1])/h)+1 == length(xs))
    @assert(length(xs) == length(fs))
    @assert(length(xs)%2 == 1)
    
    s = 0.
    for i = 1 : length(xs)-1
        s += 0.5 * (fs[i] + fs[i+1]) * (xs[i+1] - xs[i])
    end
    return s
end

function simpsons_quadrature_adaptive(fn::Function, a::Real, b::Real; 
    tol=1e-6, itermax=10)
    @assert(a < b)
    @assert(hasmethod(fn, (Float64,)))
    # x1s are fine, x2 are coarse
    n = 32+1
    h1 = (b-a)/(n-1)
    h2 = 2*h1
    x1 = collect(range(a, stop=b, length=n))
    x2 = x1[1:2:end]
    f1 = fn.(x1)
    f2 = f1[1:2:end]
    r2 = simpsons_eval(x2, f2, h2)
    r1 = r2 # Just to get the correct type.
    iter = 0
    while true
        iter += 1
        r1 = simpsons_eval(x1, f1, h1)
        rerr = abs(r1 - r2) / abs(r1)
        if rerr*2 < tol
            break
        end
        if iter > itermax
            break
        end
        n = (n-1)*2 + 1
        h1 = (b-a)/(n-1)
        h2 = 2*h1
        x2 = x1
        x1 = collect(range(a, stop=b, length=n))
        f2 = f1
        f1 = zeros(n)
        f1[1:2:end] = f2
        f1[2:2:end] = fn.(x1[2:2:end])
        r2 = r1
    end
    return r1
end

function simpsons_eval(
    xs::Vector{<:Number}, fs::Vector{<:Number}, h)

    @assert(round((xs[end]-xs[1])/h)+1 == length(xs))
    @assert(length(xs) == length(fs))
    @assert(all((xs[2:end]-xs[1:end-1]) .- h .< h * 1e-14))
    @assert((length(xs)-1)%2 == 0)
    
    s = 0.
    for i = 1 : 2 : length(xs)-2
        s += h * (fs[i] + 4*fs[i+1] + fs[i+2]) / 3
    end
    return s
end

#= Numerical evaluation of finite part integrals ---------------------------=#
# Using method from D.H. Padget, The numerical evaluation of hadamard finite
# part integrals, Numerische mathematik 1981

# Integrate[ f(x) / (x-s)^2, {x, -1, 1} ]
# Integrating in x = [-1, 1]. Legendre.
function integrate_finite_part_legendre(
    f :: Function, fderiv ::Function, s :: Real;
    n = 50)
    q0 = log((1-s)/(1+s))
    q0p = 2 / (s^2 - 1)
    fs = f(s)
    fsp = fderiv(s)

    points, weights = FastGaussQuadrature.gausslegendre(n)
    integrand = x-> (f(x)-fs)/(x-s)^2 - fsp / (x-s)
    summation = mapreduce(x->x[2] * integrand(x[1]), +, zip(points, weights))
    integral = summation + q0p*fs +q0*fsp
    return integral
end

# Integrate[ f(x) / (sqrt(1-x^2) * (x-s)^2), {x, -1, 1} ]
# Integrating in x = [-1, 1]. Chebyshev type 1.
function integrate_finite_part_chebyshev1(
    f :: Function, fderiv ::Function, s :: Real;
    n = 50)
    q0 = 0
    q0p = 0
    fs = f(s)
    fsp = fderiv(s)

    points, weights = FastGaussQuadrature.gausschebyshev(n, 1)
    integrand = x-> (f(x)-fs)/(x-s)^2 - fsp / (x-s)
    summation = mapreduce(x->x[2] * integrand(x[1]), +, zip(points, weights))
    integral = summation + q0p*fs +q0*fsp
    return integral
end

# Integrate[ f(x)sqrt(1-x^2) / (x-s)^2, {x, -1, 1} ]
# Integrating in x = [-1, 1]. Chebyshev type 2.
#
# TESTING:
# f(x) = 1, s=-0.2 -> int = -3.14159 - 1.11022*10^-16 I
# f(x) = x, s=0.4 -> int = -2.51327 + 0. I
# f(x) = x^2, s=0.3 -> int = 0.722566 + 0. I
function integrate_finite_part_chebyshev2(
    f :: Function, fderiv ::Function, s :: Real;
    n = 50)
    q0 = -pi * s
    q0p = -pi
    fs = f(s)
    fsp = fderiv(s)

    points, weights = FastGaussQuadrature.gausschebyshev(n, 2)
    integrand = x-> (f(x)-fs)/(x-s)^2 - fsp / (x-s)
    summation = mapreduce(x->x[2] * integrand(x[1]), +, zip(points, weights))
    integral = summation + q0p*fs +q0*fsp
    return integral
end

#= Laplace transform -------------------------------------------------------=#
function laplace(
    function_in_t :: Function, s :: Real)

    nodes, weights = FastGaussQuadrature.gausslaguerre(100)
    integrand = x -> function_in_t(x / s) / s
    evals = map(integrand, nodes)
    integral = sum(weights .* evals)
    return integral
end

#= Inverse Laplace transforms ----------------------------------------------=#
function gaver_stehfest(
    function_in_s :: Function, t :: Real, N :: Int)

    # Gaver-Stehfest method.
    @assert(hasmethod(function_in_s, (Float64,)), "Input method will not "*
        "accept a F64 as argument in for Gaver-Stehfest inverse laplace.")
    @assert(N > 0, "Taylor approximation of transform must have positive"*
        " number of terms. (Given N <= 0)")
    @assert((N%2) == 0, "N (number of terms) must be even.")

    function Vk(k :: Int, N :: Int)
        N2 = N / 2
        term1i = (-1)^(k + N2)
        term2i = mapreduce(
            x->x^(N2) * factorial(2 * x) /
                (factorial(N2 - x) * factorial(x) * factorial(x - 1) *
                factorial(k - x) * factorial(2*x - k)),
            +,
            collect(floor((k+1)/2) : minimum((k, N/2)))
        )
        return term1i * term2i
    end
    term1 = log(2) / t
    term2 = mapreduce(
        x-> Vk(x, N) * function_in_s(x * term1),
        +,
        collect(1 : N)
    )
    return term1 * term2
end

#= Special functions -------------------------------------------------------=#
"""
The Eldredge ramp function is a suggested canonical kinematic from
Résumé of the AIAA FDTC Low Reynolds Number Discussion Group’s Canonical Cases,
M.V. Ol, A. Altman, J.D. Eldredge, D.J. Garmann, and Y. Lian,
48th AIAA Aerospace Sciences Meeting Including the New Horizons Forum and 
Aerospace Exposition, 4 - 7 January 2010, Orlando, Florida.
AIAA 2010-1085
"""
function eldredge_ramp(
    t::Real, 
    t1::Real, t2::Real, t3::Real, t4::Real, 
    U_inf::Real, chord::Real; a::Real=-1, sigma::Real=0.9)
    @assert(chord > 0, "Chord must be positive.")
    @assert(U_inf > 0, "Reference velocity must be positive.")
    @assert(sigma > 0, "Free parameter a must be positive.")
    @assert(sigma < 1, "Sigma must be in [0,1]")
    @assert(t1 < t2 < t3 < t4, "Time parameters must be in order.")
    a = a > 0 ? a : pi^2 / (4 * (t2 - t1) * (1 - sigma))
    t11n = cosh(a * U_inf * (t-t1) / chord) * cosh(a * U_inf * (t-t4) / chord)
    t11d = cosh(a * U_inf * (t-t2) / chord) * cosh(a * U_inf * (t-t3) / chord) 
    return log(t11n / t11d)
end

function make_normalised_eldredge_ramp(
    t1::Real, t2::Real, t3::Real, t4::Real, U_inf::Real, chord::Real; 
    a::Real=-1, sigma::Real=0.9) :: Function

    fn = t->eldredge_ramp(t, t1, t2, t3, t4, U_inf, chord; 
        a=a, sigma=sigma)
    fn_max = fn((t2 + t3)/2)
    normalised_fn = t->fn(t) / fn_max
    return normalised_fn
end

#- Struve functions - homebaked ----------------------------------------------

function struve_l(v::Int, z::Number)
    return -im * exp(- im * pi * v / 2) * struve_h(v, im * z)
end

function struve_k(v::Int, z::Number)
    return struve_h(v, z) - SpecialFunctions.bessely(v, z)
end

function struve_m(v::Int, z::Number)
    return struve_l(v, z) - SpecialFunctions.besseli(v, z)
end

function struve_h(v::Int, z::Number)
    if v == 0
        return struve_h0_composite(z)
    elseif v == 1
        return struve_h1_composite(z)
    elseif v == -1
        return 1/(pi/2) - struve_h1_composite(z)
    else
        error("Not yet implemented. ")
    end
end

function struve_h0_power_series(z::Number; terms=60)
    sum = 0.
    num = -1/z
    den = 1.
    zsq = z^2
    for n = 1 : terms
        num *= -zsq
        den *= (2 * n - 1)^2
        sum += num / den
    end
    return sum * 2 / pi
end

function struve_h1_power_series(z::Number; terms=60)
    sum = 0.
    num = ComplexF64(-1.)
    den = 1.
    zsq = z^2
    for n = 1 : terms
        num *= -zsq
        den *= (2*n - 1) * (2*n + 1)
        sum += num / den
    end
    return sum * 2 / pi
end

function struve_h0_laurent_bigz(z::Number; terms=10)
    sum = 0.
    zsq = 1/z^2
    term = -z
    for n = 1 : terms
        term *= -zsq * (2*n - 3)^2
        sum += term
    end
    ret = sum * 2 / pi + SpecialFunctions.bessely(0, z)
    return ret
end

function struve_h1_laurent_bigz(z::Number; terms=10)
    sum = 1.
    zsq = 1/z^2
    term = 1
    for n = 1 : terms-1
        term *= -zsq * (2*n - 3) * (2*n - 1)
        sum += term
    end
    ret = sum * 2 / pi + SpecialFunctions.bessely(1, z)
    return ret
end

function struve_h0_composite(z::Number)
    if abs(z) > 20
        ret = struve_h0_laurent_bigz(z; terms=9)
    else
        ret = struve_h0_power_series(z; terms=60)
    end
    return ret
end

function struve_h1_composite(z::Number)
    if abs(z) > 20
        ret = struve_h1_laurent_bigz(z; terms=9)
    else
        ret = struve_h1_power_series(z; terms=60)
    end
    return ret
end

#   EXPONENTIAL INTEGRAL                                                      
#   Julia does not have a exponential integral implementation. This is 
#   copied from 
#   https://github.com/mschauer/Bridge.jl/blob/master/src/expint.jl            
#   under MIT lisense. Credit to stevengj and mschauer.                                    

using Base.MathConstants: eulergamma

# n coefficients of the Taylor series of E₁(z) + log(z), in type T:
function E₁_taylor_coefficients(::Type{T}, n::Integer) where T<:Number
    n < 0 && throw(ArgumentError("$n ≥ 0 is required"))
    n == 0 && return T[]
    n == 1 && return T[-eulergamma]
    # iteratively compute the terms in the series, starting with k=1
    term::T = 1
    terms = T[-eulergamma, term]
    for k in 2:n
        term = -term * (k-1) / (k * k)
        push!(terms, term)
    end
    return terms
end

# inline the Taylor expansion for a given order n, in double precision
macro E₁_taylor64(z, n::Integer)
    c = E₁_taylor_coefficients(Float64, n)
    taylor = :(@evalpoly zz)
    append!(taylor.args, c)
    quote
        let zz = $(esc(z))
            $taylor - log(zz)
        end
    end
end

# for numeric-literal coefficients: simplify to a ratio of two polynomials:
import Polynomials
# return (p,q): the polynomials p(x) / q(x) corresponding to E₁_cf(x, a...),
# but without the exp(-x) term
function E₁_cfpoly(n::Integer, ::Type{T}=BigInt) where T<:Real
    q = Polynomials.Polynomial(T[1])
    p = x = Polynomials.Polynomial(T[0,1])
    for i in n:-1:1
        p, q = x*p+(1+i)*q, p # from cf = x + (1+i)/cf = x + (1+i)*q/p
        p, q = p + i*q, p     # from cf = 1 + i/cf = 1 + i*q/p
    end
    # do final 1/(x + inv(cf)) = 1/(x + q/p) = p/(x*p + q)
    return p, x*p + q
end
macro E₁_cf64(z, n::Integer)
    p, q = E₁_cfpoly(n, BigInt)
    num_expr =  :(@evalpoly zz)
    append!(num_expr.args, Float64.(Polynomials.coeffs(p)))
    den_expr = :(@evalpoly zz)
    append!(den_expr.args, Float64.(Polynomials.coeffs(q)))
    quote
        let zz = $(esc(z))
            exp(-zz) * $num_expr / $den_expr
        end
    end
end

# exponential integral function E₁(z)
function expint(z::Union{Float64,Complex{Float64}})
    x² = real(z)^2
    y² = imag(z)^2
    if real(z) > 0 && x² + 0.233*y² ≥ 7.84 # use cf expansion, ≤ 30 terms
        if (x² ≥ 546121) & (real(z) > 0) # underflow
            return zero(z)
        elseif x² + 0.401*y² ≥ 58.0 # ≤ 15 terms
            if x² + 0.649*y² ≥ 540.0 # ≤ 8 terms
                x² + y² ≥ 4e4 && return @E₁_cf64 z 4
                return @E₁_cf64 z 8
            end
            return @E₁_cf64 z 15
        end
        return @E₁_cf64 z 30
    else # use Taylor expansion, ≤ 37 terms
        r² = x² + y²
        return r² ≤ 0.36 ? (r² ≤ 2.8e-3 ? (r² ≤ 2e-7 ? @E₁_taylor64(z,4) :
                                                       @E₁_taylor64(z,8)) :
                                                       @E₁_taylor64(z,15)) :
                                                       @E₁_taylor64(z,37)
    end
end

# END SpecialisedFunctions.jl
#============================================================================#
