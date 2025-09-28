\# **KipuBank**

Contrato inteligente en Solidity que implementa una \*\*bóveda personal de ETH\*\* con límites configurables de capacidad global y retiro máximo por usuario.  
Los usuarios pueden \*\*depositar y retirar ETH\*\* dentro de los parámetros definidos, asegurando seguridad mediante validaciones y protección contra ataques de reentrada.

---

\## 📌 **Características principales**

\- \*\*Depósitos seguros de ETH\*\* en una bóveda personal.

\- \*\*Límite global de depósitos\*\*: capacidad máxima que el banco puede recibir.

\- \*\*Límite máximo por retiro\*\*: restringe el monto que se puede retirar en una sola transacción.

\- \*\*Eventos\*\* para depósitos y retiros exitosos.

\- \*\*Protección contra reentrancy\*\* gracias a `ReentrancyGuard` de OpenZeppelin.

\- \*\*Validaciones personalizadas\*\* con errores claros en caso de fallos.

---

\## ⚙️ **Despliegue**

\###  **Opción 1: Remix IDE**

1\. Entrar a \[Remix IDE](https://remix.ethereum.org/).

2\. Crear un nuevo archivo `KipuBank.sol` y pegá el código del contrato.

3\. Compilar con el compilador `0.8.30`.

4\. En la pestaña \*\*Deploy \& Run Transactions\*\*:

&nbsp;  - Elegí el entorno:

&nbsp;    - \*\*Remix VM\*\* → entorno local dentro del navegador.

&nbsp;    - \*\*Injected Provider (MetaMask)\*\* → despliegue en una red real/testnet (Sepolia, Goerli, etc.).

&nbsp;  - Ingresar los parámetros del constructor, por ejemplo:

&nbsp;    ```

&nbsp;    \_limiteGlobalDepositos = 1000

&nbsp;    \_limiteRetiro = 10

&nbsp;    ```

&nbsp;  - Hacer click en \*\*Deploy\*\*.

5\. Copiar la dirección del contrato desplegado para interactuar luego.

---

\###  **Opción 2: ethers.js con JsonRpcProvider**

Es posible desplegar e interactuar con el contrato usando \[ethers.js](https://docs.ethers.org/).

\#### Requisitos

\- Node.js >= 18

\- ethers.js

\- Una RPC de red (Ganache, Hardhat, Infura, Alchemy, etc.)

\#### Despliegue de ejemplo (`deploy.js`):

&nbsp;	const { ethers } = require("ethers");

&nbsp;	require("dotenv").config();

&nbsp;	async function main() {

&nbsp; 		const provider = new ethers.JsonRpcProvider(process.env.RPC\_URL);

&nbsp; 		const signer = new ethers.Wallet(process.env.PRIVATE\_KEY, provider);

&nbsp; 		// ABI y bytecode generados al compilar con Hardhat o Remix

&nbsp; 		const contractABI = require("./KipuBankABI.json").abi;

&nbsp;	 	const contractBytecode = require("./KipuBankABI.json").bytecode;

&nbsp;	 	const factory = new ethers.ContractFactory(contractABI, contractBytecode, signer);

&nbsp; 		console.log("⏳ Desplegando contrato...");

&nbsp; 		const contract = await factory.deploy(1000, 10); // 1000 ETH de capacidad, 10 ETH por retiro

&nbsp; 		await contract.waitForDeployment();

&nbsp;	 	console.log("✅ KipuBank desplegado en:", contract.target);

&nbsp;		}

---

🤝 **Interacción**

Una vez desplegado, es posible interactuar con el contrato usando ethers.js.
Dentro de la carpeta contracts se encuentra la ABI del contrato.

Ejemplo de interacción (interact.js):

&nbsp;	const { ethers } = require("ethers");

&nbsp;	require("dotenv").config();

&nbsp;	const provider = new ethers.JsonRpcProvider(process.env.RPC\_URL);

&nbsp;	const signer = new ethers.Wallet(process.env.PRIVATE\_KEY, provider);

&nbsp;	const contractABI = require("./KipuBankABI.json").abi;

&nbsp;	const contract = new ethers.Contract(process.env.CONTRACT\_ADDRESS, contractABI, signer);

&nbsp;	// 🔹 1. Depositar ETH

&nbsp;	await contract.depositar({ value: ethers.parseEther("1") });

&nbsp;	// 🔹 2. Consultar saldo del usuario

&nbsp;	const saldo = await contract.saldoUsuario(await signer.getAddress());

&nbsp;	console.log("Saldo:", ethers.formatEther(saldo));

&nbsp;	// 🔹 3. Retirar ETH

&nbsp;	await contract.retirar(ethers.parseEther("0.5"));

&nbsp;	// 🔹 4. Consultar capacidad global

&nbsp;	const capacidad = await contract.capacidadGlobal();

&nbsp;	console.log("Capacidad global restante:", ethers.formatEther(capacidad));

Variables de entorno necesarias (.env):

&nbsp; RPC\_URL=https://sepolia.infura.io/v3/TU\_PROJECT\_ID

&nbsp; PRIVATE\_KEY=0xTU\_CLAVE\_PRIVADA

&nbsp; CONTRACT\_ADDRESS=0xDIRECCION\_DEL\_CONTRATO

---

📢 **Eventos**

KipuBank\_DepositoRealizado(address usuario, uint256 cantidad, uint256 saldoNuevo)

KipuBank\_RetiroRealizado(address usuario, uint256 cantidad, uint256 saldoNuevo)

---

⚠️ **Errores personalizados**

KipuBank\_CapacidadBancoExcedida(cantidadSolicitada, capacidadDisponible)

KipuBank\_LimiteRetiroExcedido(cantidadSolicitada, limiteRetiro)

KipuBank\_SaldoInsuficiente(cantidadSolicitada, saldoDisponible)

KipuBank\_CantidadCero(contexto) // para evitar retiros/depósitos de cantidad 0 o despliegue con parámetros iguales a 0

KipuBank\_TransferenciaFallida(usuario, montoTransaccion)

---

📄 **Licencia**

Este proyecto está licenciado bajo la MIT License





