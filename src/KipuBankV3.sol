// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title KipuBankV3
 * @author TuNombre
 * @notice Contrato bancario que acepta ETH, USDC y cualquier ERC20 con par directo USDC en Uniswap V2
 * @dev Realiza swaps automáticos a USDC y mantiene balances internos en USDC
 * @dev Desplegado en Sepolia: Router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D, USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
 */

// IMPORTS OPTIMIZADOS
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);
    
    function getAmountsOut(uint amountIn, address[] calldata path) 
        external 
        view 
        returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
}

contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====================
    // ===== CONSTANTES ====
    // ====================
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
    uint256 public constant USDC_DECIMALS = 6;
    uint256 private constant MAX_DEADLINE_EXTENSION = 1 hours;

    // ====================
    // ===== INMUTABLES ====
    // ====================
    IERC20 public immutable i_usdc;
    IUniswapV2Router02 public immutable i_router;
    address public immutable i_weth;
    uint256 public immutable i_bankCap;

    // ====================
    // ===== VARIABLES ====
    // ====================
    mapping(address => uint256) public s_usdcBalances;
    uint256 public s_totalUSDC;
    uint256 public s_deposits;
    uint256 public s_withdrawals;

    // ====================
    // ===== EVENTOS ======
    // ====================
    event DepositUSDC(address indexed user, uint256 amount);
    event DepositAndSwap(address indexed user, address tokenIn, uint256 amountIn, uint256 usdcOut);
    event DepositETHAndSwap(address indexed user, uint256 ethIn, uint256 usdcOut);
    event WithdrawUSDC(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed admin, address token, uint256 amount);
    event CapExceeded(address indexed user, uint256 attemptedAmount, uint256 availableCap);

    // ====================
    // ===== ERRORES ======
    // ====================
    error KipuBank_BankCapExceeded(uint256 cap, uint256 attempted);
    error KipuBank_InsufficientBalance(uint256 requested, uint256 available);
    error KipuBank_ZeroAmount();
    error KipuBank_InvalidAddress();
    error KipuBank_DeadlinePassed();
    error KipuBank_InsufficientOutput(uint256 expected, uint256 actual);
    error KipuBank_InvalidPath();

    // ====================
    // ===== MODIFIERS ====
    // ====================
    modifier validAddress(address _addr) {
        _validAddress(_addr);
        _;
    }

    modifier validDeadline(uint256 _deadline) {
        _validDeadline(_deadline);
        _;
    }

    /**
     * @param _bankCap Límite máximo del banco en unidades USDC (6 decimales)
     * @param _router Dirección del Router Uniswap V2 (Sepolia: 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D)
     * @param _usdc Dirección del token USDC (Sepolia: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238)
     * @param _admin Dirección del administrador
     */
    constructor(
        uint256 _bankCap,
        address _router,
        address _usdc,
        address _admin
    ) 
        validAddress(_router)
        validAddress(_usdc)
        validAddress(_admin)
    {
        i_bankCap = _bankCap;
        i_router = IUniswapV2Router02(_router);
        i_usdc = IERC20(_usdc);
        i_weth = i_router.WETH();

        // Verificar que USDC tenga 6 decimales
        try IERC20Metadata(_usdc).decimals() returns (uint8 decimals) {
            require(decimals == USDC_DECIMALS, "USDC debe tener 6 decimales");
        } catch {
            revert("Error obteniendo decimales USDC");
        }

        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ====================
    // ===== DEPÓSITOS ====
    // ====================

    /**
     * @notice Depositar USDC directamente
     * @param _amount Cantidad en USDC (6 decimales)
     */
    function depositUSDC(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert KipuBank_ZeroAmount();

        uint256 newTotal = s_totalUSDC + _amount;
        if (newTotal > i_bankCap) {
            revert KipuBank_BankCapExceeded(i_bankCap, newTotal);
        }

        i_usdc.safeTransferFrom(msg.sender, address(this), _amount);

        s_usdcBalances[msg.sender] += _amount;
        s_totalUSDC = newTotal;
        s_deposits++;

        emit DepositUSDC(msg.sender, _amount);
    }

    /**
     * @notice Depositar cualquier ERC20 con par directo USDC en Uniswap V2
     * @param _tokenIn Dirección del token a depositar
     * @param _amountIn Cantidad de tokens a depositar
     * @param _minUSDCOut Mínimo USDC aceptable (protección contra slippage)
     * @param _deadline Límite de tiempo para la transacción
     */
    function depositERC20AndSwapToUSDC(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _minUSDCOut,
        uint256 _deadline
    ) 
        external 
        nonReentrant 
        validAddress(_tokenIn)
        validDeadline(_deadline)
    {
        if (_amountIn == 0) revert KipuBank_ZeroAmount();
        if (_tokenIn == address(i_usdc)) revert KipuBank_InvalidAddress();

        // Verificar capacidad ANTES del swap
        uint256 estimatedUSDC = _estimateSwapOutput(_amountIn, _tokenIn);
        if (s_totalUSDC + estimatedUSDC > i_bankCap) {
            emit CapExceeded(msg.sender, estimatedUSDC, i_bankCap - s_totalUSDC);
            revert KipuBank_BankCapExceeded(i_bankCap, s_totalUSDC + estimatedUSDC);
        }

        // Transferir tokens del usuario
        uint256 received = _pullToken(_tokenIn, _amountIn);

        // Aprobar router
        IERC20(_tokenIn).safeIncreaseAllowance(address(i_router), received);

        // Construir path: tokenIn -> USDC
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = address(i_usdc);

        // Verificar que el path sea válido
        if (!_isValidPath(path)) revert KipuBank_InvalidPath();

        uint256 balanceBefore = i_usdc.balanceOf(address(this));

        i_router.swapExactTokensForTokens(received, _minUSDCOut, 
        path, address(this), _deadline);

        uint256 balanceAfter = i_usdc.balanceOf(address(this));
        uint256 usdcReceived = balanceAfter - balanceBefore;

        // Verificar output mínimo
        if (usdcReceived < _minUSDCOut) {
            revert KipuBank_InsufficientOutput(_minUSDCOut, usdcReceived);
        }

        // Verificación final del cap
        if (s_totalUSDC + usdcReceived > i_bankCap) {
            // Reembolsar USDC al usuario en caso de error
            i_usdc.safeTransfer(msg.sender, usdcReceived);
            revert KipuBank_BankCapExceeded(i_bankCap, s_totalUSDC + usdcReceived);
        }

        // Actualizar balances
        s_usdcBalances[msg.sender] += usdcReceived;
        s_totalUSDC += usdcReceived;
        s_deposits++;

        emit DepositAndSwap(msg.sender, _tokenIn, received, usdcReceived);
    }

    /**
     * @notice Depositar ETH, convertirlo a USDC y acreditar al usuario
     * @param _minUSDCOut Mínimo USDC aceptable (protección contra slippage)
     * @param _deadline Límite de tiempo para la transacción
     */
    function depositETHAndSwapToUSDC(
        uint256 _minUSDCOut, 
        uint256 _deadline
    ) 
        external 
        payable 
        nonReentrant 
        validDeadline(_deadline)
    {
        uint256 ethIn = msg.value;
        if (ethIn == 0) revert KipuBank_ZeroAmount();

        // Verificar capacidad ANTES del swap
        uint256 estimatedUSDC = _estimateSwapOutput(ethIn, i_weth);
        if (s_totalUSDC + estimatedUSDC > i_bankCap) {
            emit CapExceeded(msg.sender, estimatedUSDC, i_bankCap - s_totalUSDC);
            revert KipuBank_BankCapExceeded(i_bankCap, s_totalUSDC + estimatedUSDC);
        }

        address[] memory path = new address[](2);
        path[0] = i_weth;
        path[1] = address(i_usdc);

        uint256 balanceBefore = i_usdc.balanceOf(address(this));

        // Ejecutar swap ETH -> USDC
        i_router.swapExactETHForTokens{value: ethIn}(
            _minUSDCOut,
            path,
            address(this),
            _deadline
        );

        uint256 balanceAfter = i_usdc.balanceOf(address(this));
        uint256 usdcReceived = balanceAfter - balanceBefore;

        // Verificar output mínimo
        if (usdcReceived < _minUSDCOut) {
            revert KipuBank_InsufficientOutput(_minUSDCOut, usdcReceived);
        }

        // Verificación final del cap
        if (s_totalUSDC + usdcReceived > i_bankCap) {
            i_usdc.safeTransfer(msg.sender, usdcReceived);
            revert KipuBank_BankCapExceeded(i_bankCap, s_totalUSDC + usdcReceived);
        }

        s_usdcBalances[msg.sender] += usdcReceived;
        s_totalUSDC += usdcReceived;
        s_deposits++;

        emit DepositETHAndSwap(msg.sender, ethIn, usdcReceived);
    }

    // ====================
    // ===== RETIROS ======
    // ====================

    /**
     * @notice Retirar USDC del vault
     * @param _amount Cantidad en USDC (6 decimales)
     */
    function withdrawUSDC(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert KipuBank_ZeroAmount();
        
        uint256 userBalance = s_usdcBalances[msg.sender];
        if (_amount > userBalance) {
            revert KipuBank_InsufficientBalance(_amount, userBalance);
        }

        s_usdcBalances[msg.sender] = userBalance - _amount;
        s_totalUSDC -= _amount;
        s_withdrawals++;

        i_usdc.safeTransfer(msg.sender, _amount);

        emit WithdrawUSDC(msg.sender, _amount);
    }

    // ====================
    // ===== CONSULTAS ====
    // ====================

    /**
     * @notice Obtener balance USDC de un usuario
     * @param _user Dirección del usuario
     * @return Balance en USDC
     */
    function getUSDCBalance(address _user) external view returns (uint256) {
        return s_usdcBalances[_user];
    }

    /**
     * @notice Obtener balance USDC del contrato
     * @return Balance total en USDC
     */
    function contractUSDCBalance() external view returns (uint256) {
        return i_usdc.balanceOf(address(this));
    }

    /**
     * @notice Calcular capacidad disponible del banco
     * @return Capacidad restante en USDC
     */
    function availableCapacity() external view returns (uint256) {
        return s_totalUSDC >= i_bankCap ? 0 : i_bankCap - s_totalUSDC;
    }

    /**
     * @notice Estimar output de swap
     * @param _amountIn Cantidad de entrada
     * @param _tokenIn Token de entrada (usar i_weth para ETH)
     * @return USDC estimado que se recibirá
     */
    function estimateSwapOutput(uint256 _amountIn, address _tokenIn) 
        external 
        view 
        returns (uint256) 
    {
        return _estimateSwapOutput(_amountIn, _tokenIn);
    }

    // ====================
    // ===== ADMIN ========
    // ====================

    /**
     * @notice Retiro de emergencia de tokens (solo admin)
     * @param _token Dirección del token (address(0) para ETH)
     * @param _to Dirección destino
     */
    function emergencyWithdrawToken(address _token, address _to) 
        external 
        onlyRole(ADMIN_ROLE) 
        nonReentrant 
        validAddress(_to)
    {
        uint256 balance;
        
        if (_token == address(0)) {
            balance = address(this).balance;
            (bool success, ) = _to.call{value: balance}("");
            require(success, "Transferencia ETH fallida");
        } else {
            balance = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransfer(_to, balance);
        }
        
        emit EmergencyWithdraw(msg.sender, _token, balance);
    }

    // ====================
    // ===== INTERNAS =====
    // ====================

    function _pullToken(address _token, uint256 _amount) internal returns (uint256) {
        IERC20 token = IERC20(_token);
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 balAfter = token.balanceOf(address(this));
        return balAfter - balBefore; // Soporta tokens con fee-on-transfer
    }

    function _estimateSwapOutput(uint256 _amountIn, address _tokenIn) 
        internal 
        view 
        returns (uint256) 
    {
        if (_amountIn == 0) return 0;
        
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = address(i_usdc);
        
        try i_router.getAmountsOut(_amountIn, path) returns (uint[] memory amounts) {
            return amounts[1]; // USDC output
        } catch {
            return 0; // Si no hay par, retorna 0
        }
    }

    function _isValidPath(address[] memory _path) internal view returns (bool) {
        if (_path.length != 2) return false;
        if (_path[1] != address(i_usdc)) return false;
        
        // Verificar que el par existe estimando el output
        try i_router.getAmountsOut(1e18, _path) returns (uint[] memory amounts) {
            return amounts[1] > 0;
        } catch {
            return false;
        }
    }

    function _validAddress(address _addr) internal pure {
        if (_addr == address(0)) revert KipuBank_InvalidAddress();
    }

    function _validDeadline(uint256 _deadline) internal view {
        if (_deadline < block.timestamp) revert KipuBank_DeadlinePassed();
        if (_deadline > block.timestamp + MAX_DEADLINE_EXTENSION) revert KipuBank_DeadlinePassed();
    }

    // ====================
    // ===== RECEIVE ======
    // ====================

    receive() external payable {
        // Aceptar ETH directamente
    }

    fallback() external payable {
        // No hacer nada
    }
}