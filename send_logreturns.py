# import json
# from web3 import Web3
# import math
# import os
# from dotenv import load_dotenv

# # Load environment variables from .env
# load_dotenv()

# # Configure connection to Anvil (local node)
# w3 = Web3(Web3.HTTPProvider("http://127.0.0.1:8545"))

# # Verify connection
# assert w3.isConnected(), "Failed to connect to Ethereum node"

# # Deployed contract address (change according to your deployment)
# contract_address = "0x.."

# # Load contract ABI
# with open("out/VolatilityCalculator.sol/VolatilityCalculator.json", "r") as f:
#     contract_abi = json.load(f)["abi"]

# # Create contract instance
# contract = w3.eth.contract(address=contract_address, abi=contract_abi)

# # Address of the account that will send transactions (use Anvil's account #0)
# account = w3.eth.account.from_key(os.getenv("PRIVATE_KEY"))

# # Historical prices
# prices = [100, 105, 102, 108]

# def calculate_log_returns(prices):
#     log_returns = []
#     for i in range(1, len(prices)):
#         log_return = math.log(prices[i] / prices[i - 1])
#         log_returns.append(log_return)
#     return log_returns

# def to_64x64(value):
#     return int(value * (2**64))

# if __name__ == "__main__":
#     # Calculate logarithmic returns
#     log_returns = calculate_log_returns(prices)
#     print("Logarithmic Returns:", log_returns)

#     # Convert to 64.64 fixed point
#     log_returns_64x64 = [to_64x64(r) for r in log_returns]
#     print("Logarithmic Returns (64.64 fixed point):", log_returns_64x64)

#     # Prepare the transaction
#     # To optimize, all returns will be sent in a single transaction
#     tx = contract.functions.addLogReturns(log_returns_64x64).buildTransaction({
#         'from': account.address,
#         'nonce': w3.eth.get_transaction_count(account.address),
#         'gas': 500000,  # Adjust as necessary
#         'gasPrice': w3.toWei('1', 'gwei')  # Adjust as necessary
#     })

#     # Sign the transaction
#     signed_tx = account.sign_transaction(tx)

#     # Send the transaction
#     tx_hash = w3.eth.send_raw_transaction(signed_tx.rawTransaction)
#     print(f"Transaction sent with hash: {tx_hash.hex()}")

#     # Wait for the transaction to be mined
#     receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
#     print(f"Transaction mined in block {receipt.blockNumber}")