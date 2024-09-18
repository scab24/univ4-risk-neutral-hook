# UniswapV4 - Risk Neutral Hook


<img alt="image" src="UniV4.png" style="width: 100%; height: auto;">

[This is the explanatory video for our Hook](https://youtu.be/_3UwdIoU23w)

[You can also view the presentation slides here](https://docs.google.com/presentation/d/1V69IXV7AJSI59UxeSnM4UYf7mCy2Leu2MyUha8utA2M/edit#slide=id.g2d31d7c8c7b_7_58)

We try to provide a combined solution to hedge **IL** & **LVR** via dynamic fees and hedges to achieve both delta and gamma neutrality.

### Background

When providing liquidity to Uniswap, liquidity providers (LPs) are subject to the price mechanics of the constant function formula:

**x * y = k**

Due to LP positions having negative convexity (which can be proven using Jensen's Inequality), the value of the position will always be inferior to simply holding the tokens (without accounting for fees).

### Quantifying LP Losses

There are two main methods of quantifying the loss LPs incur:

- **Loss-Versus-HODLing**: Also known as Impermanent or Divergence Loss.
- **Loss-Versus-Rebalancing**: Also known as "lever."

While Impermanent Loss has been the primary metric for quantifying LP losses on Uniswap, it has some major drawbacks:

- It compares LP value to the value of simply holding the tokens, which is an unrealistic strategy.
- If the price diverges and then returns to the original price, IL=0, completely disregarding volatility.

Conversely, "lever" is path-dependent, taking into account rebalancing (and arbitrage) opportunities given a time series of prices. It occurs mainly due to AMMs having "stale" prices.

Moreover, it has been proven that LPs have underpriced volatility and therefore market risk, foregoing additional profits and having a negative Volatility Risk Premium. This can be demonstrated by deriving implied volatility from Uniswap positions and comparing it to realized volatility from any liquid market where price discovery is supposed to occur, such as Deribit.

### Reducing LP Losses

Given that an LP has already chosen a pool, there are two main ways of reducing these losses:

- **Using hedges**
- **Dynamically modifying pool fees**

---

## Hedges

Due to the negative convexity of the LP value function, their positions cannot be hedged solely with delta-one or linear products. However, for small price movements, a delta-hedge can be sufficient to offset "lever." This can be achieved either by:

- Selling futures
- On-chain borrowing and setting a rebalance threshold, from which, if surpassed, a re-hedge is executed.

For LPs desiring a complete hedge to offset all directional risk, products like power perpetuals or options are the preferred approach.

We implement a basic Proof of Concept (PoC) of how LP Greeks are updated and how this can be used to compute any hedging updates, verifying that the position is correctly hedged.

---

## Dynamic Fees

To correctly remunerate LPs and price volatility accordingly, as well as reduce price impact for large swaps and account for market conditions via gas price, a dynamic fee system has been implemented.

To achieve this, we extract the implied volatility of the pool from volatile asset drift and the return from pool fees using the formula derived by **Daniel Alcarraz**.

We attempted to devise a simple model that dynamically adjusts the fees with a discount factor based on the **Volatility Risk Premium**—that is, the difference between Implied and Realised Volatility.

- **Whenever implied volatility is higher** than historical or expected volatility, providing liquidity yields a positive expected return.
  
- **If the implied volatility is lower**, the return becomes negative. 

> *“If the implied volatility is lower than the historical or expected volatility, the return becomes negative.”* - Daniel Alcarraz

We are also currently investigating the Implied Volatility formula proposed by **Guillaume Lambert**. There is significant room for improvement in both the parameters and the formulas.

These are preliminary implementations to have the Proof-of-Concept ready for the hackathon but will likely change in the following weeks. We will also be performing:

- A backend (taking care to avoid backtesting overfitting)
- A forward test of the models
- Unit, integration, and fuzz tests
- Formal verification of all the code