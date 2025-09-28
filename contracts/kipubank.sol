// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title KipuBank
 * @author Gian Franco Magliotti Mendiburu
 * @notice Contrato de bóveda personal para depósitos y retiros de ETH con límites de capacidad y transacción.
 */
contract KipuBank is ReentrancyGuard {
    // ========== VARIABLES DE ESTADO ========== //
    /** @notice Límite global de depósitos en el banco. */
    uint256 public immutable limiteGlobalDepositos;

    /** @notice Límite máximo por retiro. */
    uint256 public immutable limiteRetiro;

    /** @notice Saldo total depositado en el banco. */
    uint256 public saldoTotalBanco;

    /** @notice Contador de depósitos totales realizados. */
    uint256 public contadorDepositos;

    /** @notice Contador de retiros totales realizados. */
    uint256 public contadorRetiros;

    /** @notice Mapping para almacenar saldos de cada usuario. */
    mapping(address usuario => uint256 saldo) private s_saldosUsuarios;

    // ========== EVENTOS ========== //
    /** @notice Evento emitido al depositar ETH exitosamente. */
    event KipuBank_DepositoRealizado(address indexed usuario, uint256 cantidad, uint256 saldoNuevo);

    /** @notice Evento emitido al retirar ETH exitosamente. */
    event KipuBank_RetiroRealizado(address indexed usuario, uint256 cantidad, uint256 saldoNuevo);

    // ========== ERRORES PERSONALIZADOS ========== //
    /** @notice Error emitido cuando se excede la capacidad del banco. */
    error KipuBank_CapacidadBancoExcedida(uint256 cantidadSolicitada, uint256 capacidadDisponible);

    /** @notice Error emitido cuando se excede el límite de retiro. */
    error KipuBank_LimiteRetiroExcedido(uint256 cantidadSolicitada, uint256 limiteRetiro);

    /** @notice Error emitido cuando hay saldo insuficiente. */
    error KipuBank_SaldoInsuficiente(uint256 cantidadSolicitada, uint256 saldoDisponible);

    /** @notice Error emitido cuando falla una transaccion. */
    error KipuBank_TransferenciaFallida(address  usuario, uint256 montoTransaccion);

    /** @notice Error emitido cuando algun parametro tiene valor 0 donde no corresponde. (en retiro,deposito... etc.) */
    error KipuBank_CantidadCero(string contexto);

    // ========== MODIFICADORES ========== //
    /**
     * @dev Modificador para validar que la cantidad a depositar no exceda la capacidad del banco.
     * @param cantidad Cantidad a validar.
     */
    modifier validarCapacidadBanco(uint256 cantidad) {
        if (saldoTotalBanco + cantidad > limiteGlobalDepositos) {
            revert KipuBank_CapacidadBancoExcedida(cantidad, limiteGlobalDepositos - saldoTotalBanco);
        }
        _;
    }

    /**
     * @dev Modificador para validar que la cantidad a retirar no exceda el límite de retiro.
     * @param cantidad Cantidad a validar.
     */
    modifier validarLimiteRetiro(uint256 cantidad) {
        if (cantidad > limiteRetiro) {
            revert KipuBank_LimiteRetiroExcedido(cantidad, limiteRetiro);
        }
        _;
    }

    /**
     * @dev Modificador para validar que la cantidad no sea 0
     * @param cantidad Cantidad a validar.
     * @param contexto Contexto de que valor se trata.
     */
    modifier validarNoEsCero(uint256 cantidad, string memory contexto) {
        if(cantidad == 0) {
            revert KipuBank_CantidadCero(contexto);
        }
        _;
    }
    /**
     * @dev Modificador para validar que un usuario tiene fondos suficientes al retirar.
     * @param usuario Dirección del usuario.
     * @param cantidad Cantidad a validar.
     */
    modifier validarSaldoSuficiente(address usuario, uint256 cantidad) {
        if (s_saldosUsuarios[usuario] < cantidad) {
            revert KipuBank_SaldoInsuficiente(cantidad, s_saldosUsuarios[usuario]);
        }
        _;
    }
    // ========== CONSTRUCTOR ========== //
    /**
     * @dev Inicializa el banco con un límite global y un límite de retiro.
     * @param _limiteGlobalDepositos Capacidad máxima del banco en ETH.
     * @param _limiteRetiro Límite máximo por retiro en ETH.
     */
    constructor(uint256 _limiteGlobalDepositos, uint256 _limiteRetiro) 
        validarNoEsCero(_limiteGlobalDepositos,"Limite global del banco")                                                           
        validarNoEsCero(_limiteRetiro,"Limite retiro maximo")
    {
        limiteGlobalDepositos = _limiteGlobalDepositos * 1 ether;
        limiteRetiro = _limiteRetiro * 1 ether;
    }

    // ========== FUNCIONES EXTERNAS ========== //
    /**
     * @notice Deposita ETH en la bóveda personal del usuario.
     * @dev Sigue el patrón checks-effects-interactions.
     */
    function depositar() external payable 
        validarCapacidadBanco(msg.value)
        validarNoEsCero(msg.value,"Deposito")
     {
        _actualizarSaldo(msg.sender, msg.value, false);
        saldoTotalBanco += msg.value;
        unchecked { contadorDepositos++; }
        emit KipuBank_DepositoRealizado(msg.sender,msg.value, s_saldosUsuarios[msg.sender]);
    }

    /**
     * @notice Retira ETH de la bóveda personal del usuario.
     * @dev Sigue el patrón checks-effects-interactions.
     * @param cantidad Cantidad de ETH a retirar.
     */
    function retirar(uint256 cantidad) external nonReentrant 
        validarLimiteRetiro(cantidad) 
        validarSaldoSuficiente(msg.sender,cantidad)
        validarNoEsCero(cantidad,"Retiro")
    {
        _actualizarSaldo(msg.sender, cantidad, true);
        saldoTotalBanco -= cantidad;
        unchecked { contadorRetiros++; }
        _transferirETH(msg.sender, cantidad);
        emit KipuBank_RetiroRealizado(msg.sender, cantidad, s_saldosUsuarios[msg.sender]);
    }

    // ========== FUNCIONES DE VISTA ========== //
    /**
     * @notice Obtiene el saldo del usuario que realiza la llamada.
     * @return Saldo del usuario.
     */
    function obtenerSaldo() external view returns (uint256) {
        return s_saldosUsuarios[msg.sender];
    }

    // ========== FUNCIONES PRIVADAS ========== //
    /**
     * @dev Función privada para actualizar el saldo de un usuario.
     * @param usuario Dirección del usuario.
     * @param cantidad Cantidad a añadir.
     */
    function _actualizarSaldo(address usuario, uint256 cantidad, bool esRetiro) private {
        if (esRetiro) {
            s_saldosUsuarios[usuario] -= cantidad;
        } else {
            s_saldosUsuarios[usuario] += cantidad;
        }
    }

    /**
     * @dev Función privada para transferir ETH a un usuario.
     * @param usuario Dirección del usuario.
     * @param cantidad Cantidad de ETH a transferir.
     */
    function _transferirETH(address usuario, uint256 cantidad) private {
        (bool exito, ) = usuario.call{value: cantidad}("");
        if (!exito) {
            revert KipuBank_TransferenciaFallida(usuario, cantidad);
        }
    }

    // ========== FUNCIONES ESPECIALES ========== //
    /**
     * @notice Función receive para recibir ETH directamente.
     *         Redirige a depositar() para mantener la lógica centralizada.
     */
    receive() external payable {
        this.depositar();
    }
}