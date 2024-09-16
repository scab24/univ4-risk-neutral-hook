import json
from web3 import Web3
import math
import os
from dotenv import load_dotenv

# Cargar variables de entorno desde .env
load_dotenv()

# Configurar conexión a Anvil (nodo local)
w3 = Web3(Web3.HTTPProvider("http://127.0.0.1:8545"))

# Verificar conexión
assert w3.isConnected(), "No se pudo conectar al nodo Ethereum"

# Dirección del contrato desplegado (cambiando según tu despliegue)
contrato_direccion = "0xYourContractAddressHere"

# Cargar ABI del contrato
with open("out/VolatilityCalculator.sol/VolatilityCalculator.json", "r") as f:
    contrato_abi = json.load(f)["abi"]

# Crear instancia del contrato
contrato = w3.eth.contract(address=contrato_direccion, abi=contrato_abi)

# Dirección de la cuenta que enviará las transacciones (usar cuenta #0 de Anvil)
account = w3.eth.account.from_key(os.getenv("PRIVATE_KEY"))

# Precios históricos
precios = [100, 105, 102, 108]

def calculate_log_returns(prices):
    log_returns = []
    for i in range(1, len(prices)):
        log_return = math.log(prices[i] / prices[i - 1])
        log_returns.append(log_return)
    return log_returns

def to_64x64(value):
    return int(value * (2**64))

if __name__ == "__main__":
    # Calcular retornos logarítmicos
    log_returns = calculate_log_returns(precios)
    print("Retornos Logarítmicos:", log_returns)

    # Convertir a 64.64 fija
    log_returns_64x64 = [to_64x64(r) for r in log_returns]
    print("Retornos Logarítmicos (64.64 fija):", log_returns_64x64)

    # Preparar la transacción
    # Para optimizar, se enviarán todos los retornos en una sola transacción
    tx = contrato.functions.addLogReturns(log_returns_64x64).buildTransaction({
        'from': account.address,
        'nonce': w3.eth.get_transaction_count(account.address),
        'gas': 500000,  # Ajusta según sea necesario
        'gasPrice': w3.toWei('1', 'gwei')  # Ajusta según sea necesario
    })

    # Firmar la transacción
    signed_tx = account.sign_transaction(tx)

    # Enviar la transacción
    tx_hash = w3.eth.send_raw_transaction(signed_tx.rawTransaction)
    print(f"Transacción enviada con hash: {tx_hash.hex()}")

    # Esperar a que la transacción sea minada
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"Transacción minada en bloque {receipt.blockNumber}")