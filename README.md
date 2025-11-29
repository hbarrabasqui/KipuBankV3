# 🏦 KipuBankV3 — DeFi Token Router Bank

KipuBankV3 es un protocolo bancario descentralizado que representa una evolución del diseño original de KipuBankV2. Su principal característica es la **integración nativa con protocolos DeFi** (Uniswap V2) para aceptar una amplia gama de activos, convirtiéndolos automáticamente a **USDC** antes de acreditar el saldo del usuario.

Este proyecto demuestra manejo avanzado de interacciones entre contratos, lógica de swaps, control estricto de límites de depósito (`bankCap`) y seguridad en el flujo de fondos.

---

## ✨ Características Principales

### 💰 Depósitos Multiactivo y Swaps Automáticos

El protocolo está diseñado para aceptar depósitos de múltiples activos y unificarlos en USDC, la moneda interna del banco.

| Tipo de Depósito | Flujo de Fondos |
| :--- | :--- |
| **USDC** | Depósito directo. |
| **ETH (Token Nativo)** | ETH → WETH → USDC vía Uniswap V2. |
| **ERC-20** | `TokenIn` → USDC vía Uniswap V2 (requiere par directo). |

**Lógica de Swaps:**
Si el token de entrada no es USDC, el contrato utiliza la interfaz de `IUniswapV2Router02` para ejecutar `swapExactTokensForTokens` o `swapExactETHForTokens`, depositando el USDC resultante en el contrato y acreditándolo al usuario.

### 🛡 Control de Capacidad (Bank Cap)

El contrato impone un límite máximo (`i_bankCap`) al total de USDC que puede almacenar.

* **Pre-Check:** Utiliza `getAmountsOut()` para **simular el swap** antes de que ocurra la transacción. Si la estimación excede el `bankCap`, revierte la operación preventivamente.
* **Post-Check:** Si el monto real recibido después del swap excede el `bankCap` (debido a la volatilidad/slippage), el contrato **reembolsa** el USDC al usuario y revierte la transacción.

### 🔐 Seguridad y Diseño

* **Control de Acceso:** Uso de `AccessControl` para roles de administrador.
* **Reentrancy Guard:** Protección contra reentrada en funciones críticas de depósito y retiro.
* **Contabilidad Interna:** Gestión precisa de `s_usdcBalances` por usuario y `s_totalUSDC`.
* **Mitigación de Riesgos:** El contrato **no retiene tokens no-USDC** (tokens "basura").

---

## 🧱 Arquitectura del Contrato

### `KipuBankV3.sol`

Es el contrato principal y central de la lógica, que hereda de `AccessControl` y `ReentrancyGuard`.

| Componente | Responsabilidad |
| :--- | :--- |
| **Variables Inmutables** | `i_bankCap`, `i_router`, `i_usdc`, `i_weth`. |
| **Funciones Públicas** | `depositUSDC`, `depositERC20AndSwapToUSDC`, `depositETHAndSwapToUSDC`, `withdrawUSDC`. |
| **Funciones Admin** | `emergencyWithdrawToken` (para ETH y ERC20). |

### Interfaces

* **`IUniswapV2Router02`**: Definida para la interacción con el Router de Uniswap V2.
* **OpenZeppelin**: Se utilizan `SafeERC20` y `AccessControl` para seguridad y manejo de tokens/roles.

---

## 🧭 Guía de Interacción

Asumiendo que el contrato se ha desplegado como `kipu`:

| Operación | Ejemplo de Interacción |
| :--- | :--- |
| **Aprobar USDC** | `usdc.approve(address(kipu), amount);` |
| **Depositar USDC** | `kipu.depositUSDC(amount);` |
| **Aprobar ERC20** | `token.approve(address(kipu), amount);` |
| **Depositar ERC20** | `kipu.depositERC20AndSwapToUSDC(address(token), amount, minOut, deadline);` |
| **Depositar ETH** | `kipu.depositETHAndSwapToUSDC{value: msg.value}(minOut, deadline);` |
| **Retirar USDC** | `kipu.withdrawUSDC(amountUSDC);` |

---

## 🧪 Testing y Despliegue con Foundry

### Pruebas

La suite de pruebas está desarrollada en **Foundry (`forge test`)** y alcanza una cobertura superior al 50%.

| Enfoque de Pruebas | Descripción |
| :--- | :--- |
| **Unitarias (Deterministas)** | Ejecutadas sobre un **MockRouter** para validar la lógica interna, incluyendo casos límite, montos cero y validación del `bankCap`. |
| **Negativas y Reverts** | Cubren fallas esperadas como exceder el `bankCap`, `InsufficientOutput`, rutas inválidas y direcciones no válidas. |
| **Integración** | Verificación de la correcta interacción con la interfaz `IUniswapV2Router02`. |

### Despliegue (Foundry Script)

El despliegue está automatizado vía `DeployKipuBankV3.s.sol`, compatible con `broadcast` y `verify` en Etherscan.

1.  **Configuración del Entorno (`.env`):**
    ```
    PRIVATE_KEY=0x...
    RPC_URL=[https://sepolia.infura.io/v3/TU_API_KEY](https://sepolia.infura.io/v3/TU_API_KEY)
    ETHERSCAN_API_KEY=TU_ETHERSCAN_KEY
    ```

2.  **Comando de Despliegue:**
    ```bash
    forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3 \
      --rpc-url sepolia \
      --broadcast \
      --verify \
      -vv
    ```

---

## 🛡 Análisis de Riesgos y Madurez del Protocolo

### 🔴 Riesgos Actuales (para producción)

| Riesgo | Impacto |
| :--- | :--- |
| **Dependencia de Router** | Si el router se vuelve incompatible, todos los swaps fallarán. El router es inmutable en el despliegue. |
| **Slippage** | No se implementa tolerancia de slippage variable, lo que expone a los usuarios a posibles pérdidas. |
| **Rutas Limitadas** | Asume siempre un par directo `TokenIn/USDC`. No contempla rutas complejas (e.g., `Token → WETH → USDC`). |
| **Tokens Fee-on-Transfer** | No soportados; podría llevar a errores de cálculo de `usdcReceived`. |

### 🟢 Riesgos Mitigados

* El **`bankCap`** está estrictamente controlado.
* **No se retienen** tokens intermedios o no-USDC.
* Uso de **`safeTransfer`** y validación de direcciones.
* El contrato no avanza sin la **simulación** del swap.

### 🚀 Pasos para la Madurez del Protocolo

Para alcanzar un estándar de producción DeFi, se recomienda:

1.  **Oráculos de Precios:** Integrar Chainlink para validar los resultados del swap y detectar manipulaciones de precios (MEV).
2.  **Pausability / Circuit Breaker:** Implementar una función `pause()` para detener operaciones en emergencias.
3.  **Slippage Dinámico:** Permitir al usuario definir la tolerancia de slippage.
4.  **Auditoría Externa:** Fundamental antes de manejar fondos reales.
5.  **Fuzzing Extensivo:** Ampliar las pruebas de fuzzing, incluyendo escenarios de liquidez variable y gas constraints.
