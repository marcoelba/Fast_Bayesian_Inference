# Stochastic Graient Langevin Dynamics (SGLD)

using Pkg
Pkg.status()

import Distributions
import LinearAlgebra as la
import Random
import Plots
import StatsPlots
import Zygote
import Flux
import MCMCDiagnosticTools as mcmc_dt


"""
    Generate data
"""

n = 100
p = 4

# First coefficient is the intercept
true_beta = [1.5, 1., -1., -1.5]
sigma_y = 1.

X = zeros(Float64, n, p)

Random.seed!(32143)

X[:, 1] .= 1.
# Fill 2nd and 3rd column with random Normal samples
X_dist = Distributions.Normal(0., 1.)
X[:, 2:p] = Random.rand(X_dist, (n, p-1))

# Get y = X * beta + err ~ N(0, 1)
y = X * true_beta + sigma_y * Random.rand(Distributions.Normal(), n)


"""
    Sampler parameters and distributions
"""

# Prior distribution (Isotonic Multivariate Normal = Indipendent components (specify the SD))
# beta_0 ~ N(mu=0, sigma=10)
# sigma = 0.5
beta_prior_d = Distributions.MvNormal(zeros(p), 1)

# Likelihood: y ~ N(X * beta_t, sigma=0.5)

function model_loglik(beta; X, y)
    y_mu = X * beta
    y_d = Distributions.MvNormal(y_mu, sigma_y)

    return Distributions.loglikelihood(y_d, y)
end

function prior_beta(;beta)
    return Distributions.loglikelihood(beta_prior_d, beta)
end

function loss(;beta_t, n_batches, X, y)
    return -n_batches * model_loglik(beta_t; X, y) - prior_beta(beta=beta_t)
end


"""
# Polynomial decay for the SGD learning rate
def decayed_learning_rate(step):
    step = min(step, decay_steps)
    return ((initial_learning_rate - end_learning_rate) *
            (1 - step / decay_steps) ^ (power)
        ) + end_learning_rate
"""

# Parameter update
# w(t+1) = w(t) + 0.5 * eta_t * ( grad(prior_loglik) + n_batches * grad(negative loglik) ) + eps_t
# eps_t ~ N(0, eta_t) (random noise)
# eta_t has to be polynomially decaying

random_noise_d = Distributions.Normal()

# Gradient update strategy
function sgd_grads_update(grads; eta)
    @. grads = eta * grads
    return grads
end


"""
    Features pre-processing
"""
# Continuous features normalisation (minmax in 0-1)
function minmax_normalisation(x)
    min_x = minimum(x)
    x_std = @. (x - min_x)
    max_x = maximum(x_std)
    @. x_std = x_std / max_x

    return x_std
end

Xstd = copy(X)
Xstd[:, 2] = minmax_normalisation(X[:, 2])
Xstd[:, 3] = minmax_normalisation(X[:, 3])
Xstd[:, 4] = minmax_normalisation(X[:, 4])

println(
    "Loss WRONG BETA: ",
    loss(beta_t=[10, 10, 10, 10], n_batches=1, X=Xstd, y=y)
)
println(
    "Loss TRUE BETA: ",
    loss(beta_t=true_beta, n_batches=1, X=Xstd, y=y)
)

-model_loglik(true_beta; X=Xstd, y=y)
-model_loglik([10, 10, 10, 10]; X=Xstd, y=y)


# Chain params
n_iter = 1000

# beta container
beta_hat_trace = zeros(Float64, p, n_iter)

# intial value
beta_hat_trace[:, 1] = [0., 0.1, -0.1, 0.1]
beta_hat_t = beta_hat_trace[:, 1]

""" Training loop """

iter = 1
eta_t = 0.001

for iter in range(2, n_iter)

    # take gradients
    batch_loss, batch_grads = Zygote.withgradient(beta_hat_t) do params
        loss(
            beta_t=params,
            n_batches=1,
            X=X,
            y=y
        )
    end

    # Update the gradients
    sgd_grads_update(batch_grads[1], eta=eta_t)

    # Update the parameters beta using SGD
    beta_hat_t = beta_hat_t - 0.5 * batch_grads[1] + sqrt(eta_t) * rand(random_noise_d, size(beta_hat_t))
    # beta_hat_t = beta_hat_t - batch_grads[1] + sqrt(2. * eta_t) * rand(random_noise_d, size(beta_hat_t))
    beta_hat_trace[:, iter] = beta_hat_t
    
end

# Check
beta_hat_trace

beta_hat_trace = la.transpose(beta_hat_trace)
# Trace plot
Plots.plot(beta_hat_trace)
true_beta

# Check convergence (needs multiple chains to compute between-chains variation)
mcmc_dt.rhat(
    beta_hat_trace[:, 2]
)

# Check ESS
mcmc_dt.ess(beta_hat_trace[:, 2])

subsample = range(100, n_iter, step=10)
mcmc_dt.ess(beta_hat_trace[subsample, 2])

Plots.plot(beta_hat_trace[subsample, :])


StatsPlots.density(beta_hat_trace[subsample, 2])
StatsPlots.density!(beta_hat_trace[:, 2])


# OLS
la.inv(la.transpose(X)*X) * la.transpose(X) * y


" Run sg-mcmc with RMSprop from Flux "
optimiser = Flux.Optimise.RMSProp(0.01)

# Chain params
n_iter = 1000

# beta container
beta_hat_trace = zeros(Float64, p, n_iter)

# intial value
beta_hat_trace[:, 1] = [0., 0.1, -0.1, 0.1]
beta_hat_t = beta_hat_trace[:, 1]

# Training loop

iter = 1

for iter in range(2, n_iter)

    # take gradients
    batch_loss, batch_grads = Zygote.withgradient(beta_hat_t) do params
        loss(
            beta_t=params,
            n_batches=1,
            X=X,
            y=y
        )
    end

    # Update the gradients
    Flux.Optimise.update!(optimiser, beta_hat_t, batch_grads[1])
    lr_t = optimiser.eta

    # Add the random noise to beta following the sg-mcmc rules
    beta_hat_t = beta_hat_t + sqrt(lr_t) * rand(random_noise_d, size(beta_hat_t))
    # beta_hat_t = beta_hat_t - 0.5 * batch_grads[1] + sqrt(lr_t) * rand(random_noise_d, size(beta_hat_t))

    beta_hat_trace[:, iter] = beta_hat_t
    
end


beta_hat_trace = la.transpose(beta_hat_trace)
# Trace plot
Plots.plot(beta_hat_trace)
true_beta

# Check convergence (needs multiple chains to compute between-chains variation)
mcmc_dt.rhat(
    beta_hat_trace[:, 2]
)

# Check ESS
mcmc_dt.ess(beta_hat_trace[:, 2])

subsample = range(100, n_iter, step=10)
mcmc_dt.ess(beta_hat_trace[subsample, 2])
