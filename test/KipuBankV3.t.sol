// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/KipuBankV3.sol";
import "forge-std/console.sol";


// ====================
// ===== MOCK ERC20 =====
// ====================

// Mock ERC20 token para testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 value) public {
        balanceOf[to] += value;
        totalSupply += value;
        emit Transfer(address(0), to, value);
    }

    function transfer(address to, uint256 value) public returns (bool) {
        require(balanceOf[msg.sender] >= value, "Insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        require(balanceOf[from] >= value, "Insufficient balance");
        require(allowance[from][msg.sender] >= value, "Insufficient allowance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;
        emit Transfer(from, to, value);
        return true;
    }
}

// ====================
// ===== MOCK ROUTER =====
// ====================

// Mock Uniswap Router para testing 
contract MockUniswapRouter {
    address public WETH;
    // La tasa de cambio (rate) se almacena con 18 decimales.
    mapping(address => mapping(address => uint256)) public exchangeRates;
    address public immutable USDC_ADDRESS;

    constructor(address _weth, address _usdc) {
        WETH = _weth;
        USDC_ADDRESS = _usdc;
    }

    function setExchangeRate(address from, address to, uint256 rate) external {
        exchangeRates[from][to] = rate;
    }

    // Helper para el cálculo de swap, asumiendo rate en 18 decimales
    function _calculateAmountOut(uint256 amountIn, address tokenIn, address tokenOut) 
        internal 
        view 
        returns (uint256 amountOut) 
    {
        uint256 rate = exchangeRates[tokenIn][tokenOut];
        require(rate > 0, "No exchange rate set");

        // Determinar decimales de entrada
        uint256 decimalsIn;
        if (tokenIn == WETH) {
            decimalsIn = 18;
        } else {
            decimalsIn = MockERC20(tokenIn).decimals();
        }
        
        // Determinar decimales de salida (USDC tiene 6)
        uint256 decimalsOut = MockERC20(tokenOut).decimals(); // Asumimos que es USDC (6)
        
        // Conversión: (Input * Rate / 10^18) * (10^DecimalsOut / 10^DecimalsIn)
        
        // 1. Aplicar la tasa y normalizar a 18 decimales (base de la tasa)
        uint256 intermediateAmount = (amountIn * rate) / (10**decimalsIn); 
        
        // 2. Ajustar los decimales al target (USDC tiene 6)
        amountOut = intermediateAmount / (10**(18 - decimalsOut)); 
    }

    function getAmountsOut(uint amountIn, address[] calldata path) 
        external 
        view 
        returns (uint[] memory amounts) 
    {
        require(path.length >= 2, "Invalid path");
        // Sólo simulamos el swap directo a USDC para este mock
        require(path[path.length - 1] == USDC_ADDRESS, "Invalid path target in mock");

        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        // Asume path.length == 2 para simplificar la lógica del mock
        amounts[1] = _calculateAmountOut(amountIn, path[0], path[1]);
        
        return amounts;
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts) {
        require(deadline >= block.timestamp, "Deadline passed");
        require(path.length == 2 && path[1] == USDC_ADDRESS, "Invalid path in mock");
        
        // Simular transferencia de input token (el KipuBank lo aprueba primero)
        MockERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        
        uint256 amountOut = _calculateAmountOut(amountIn, path[0], path[1]);
        require(amountOut >= amountOutMin, "Insufficient output");
        
        // Simular mint de output token (USDC) a KipuBank
        MockERC20(path[1]).mint(to, amountOut);
        
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
        return amounts;
    }

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts) {
        require(deadline >= block.timestamp, "Deadline passed");
        require(path.length == 2 && path[0] == WETH && path[1] == USDC_ADDRESS, "Invalid path in mock");
        
        uint256 amountIn = msg.value;

        uint256 amountOut = _calculateAmountOut(amountIn, WETH, path[1]);
        require(amountOut >= amountOutMin, "Insufficient output");
        
        // Simular mint de output token (USDC) a KipuBank
        MockERC20(path[1]).mint(to, amountOut);
        
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
        return amounts;
    }
}


// ====================
// ===== TEST CONTRACT =====
// ====================

contract KipuBankV3Test is Test {
    KipuBankV3 public kipuBank;
    MockERC20 public usdc;
    MockERC20 public testToken;
    MockUniswapRouter public router;
    
    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public weth;
    
    uint256 public constant BANK_CAP = 10_000_000 * 10**6; // 10M USDC (6 decimals)
    uint256 public constant INITIAL_USDC_BALANCE = 10_000 * 10**6;
    uint256 public constant INITIAL_TEST_TOKEN_BALANCE = 10 * 10**18;
    
    // Tasas de cambio (18 decimales)
    uint256 public constant ETH_USDC_RATE = 2000 * 10**18; // 1 ETH = 2000 USDC
    uint256 public constant TEST_USDC_RATE = 2 * 10**18; // 1 TEST = 2 USDC

    function setUp() public {
        // Setup accounts
        vm.deal(admin, 100 ether);
        vm.deal(user1, 6000 ether); // amplié la cantidad
        vm.deal(user2, 100 ether);

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        testToken = new MockERC20("Test Token", "TEST", 18);
        
        // Deploy mock router con mock WETH
        weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        // CORRECCIÓN: Pasar address(usdc) al constructor
        router = new MockUniswapRouter(weth, address(usdc)); 
        
        // Set exchange rates
        router.setExchangeRate(weth, address(usdc), ETH_USDC_RATE); 
        router.setExchangeRate(address(testToken), address(usdc), TEST_USDC_RATE); 
        
        // Deploy KipuBankV3
        vm.startPrank(admin);
        kipuBank = new KipuBankV3(
            BANK_CAP,
            address(router),
            address(usdc),
            admin
        );
        vm.stopPrank();

        // Fund users
        usdc.mint(user1, INITIAL_USDC_BALANCE);
        usdc.mint(user2, INITIAL_USDC_BALANCE);
        testToken.mint(user1, INITIAL_TEST_TOKEN_BALANCE);
        testToken.mint(user2, INITIAL_TEST_TOKEN_BALANCE);
        
        // Fund router with USDC for swaps
        usdc.mint(address(router), 1_000_000 * 10**6);
    }

    // ====================
    // ===== TESTS DEPÓSITO USDC =====
    // ====================

    function test_DepositUSDC_Success() public {
        uint256 depositAmount = 1000 * 10**6; // 1000 USDC
        
        vm.startPrank(user1);
        usdc.approve(address(kipuBank), depositAmount);
        kipuBank.depositUSDC(depositAmount);
        vm.stopPrank();

        assertEq(kipuBank.getUSDCBalance(user1), depositAmount);
        assertEq(kipuBank.s_totalUSDC(), depositAmount);
        assertEq(kipuBank.s_deposits(), 1);
    }

    function test_DepositUSDC_ZeroAmount() public {
        vm.startPrank(user1);
        usdc.approve(address(kipuBank), 1000);
        
        vm.expectRevert(abi.encodeWithSignature("KipuBank_ZeroAmount()"));
        kipuBank.depositUSDC(0);
        vm.stopPrank();
    }

    function test_DepositUSDC_ExceedBankCap() public {
        uint256 largeAmount = BANK_CAP + 1;
        
        vm.startPrank(user1);
        usdc.mint(user1, largeAmount);
        usdc.approve(address(kipuBank), largeAmount);
        
        vm.expectRevert(abi.encodeWithSignature("KipuBank_BankCapExceeded(uint256,uint256)", BANK_CAP, largeAmount));
        kipuBank.depositUSDC(largeAmount);
        vm.stopPrank();
    }

    // ====================
    // ===== TESTS DEPÓSITO ETH =====
    // ====================
    
    function test_DepositETHAndSwap_Success() public {
        uint256 ethAmount = 0.1 ether; // 0.1 ETH
        // Cálculo: 0.1 ETH * 2000 USDC/ETH = 200 USDC
        uint256 expectedUSDC = 200 * 10**6; 
        
        uint256 initialBalance = kipuBank.getUSDCBalance(user1);
        
        vm.startPrank(user1);
        uint256 minUSDCOut = expectedUSDC * 99 / 100; // 1% slippage
        kipuBank.depositETHAndSwapToUSDC{value: ethAmount}(
            minUSDCOut, 
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 finalBalance = kipuBank.getUSDCBalance(user1);
        // Usamos assertApproxEqAbs ya que los asserts exactos pueden fallar por cálculos intermedios.
        assertApproxEqAbs(finalBalance, initialBalance + expectedUSDC, 1, "USDC balance incorrecto");
        assertEq(kipuBank.s_deposits(), 1);
        assertTrue(kipuBank.s_totalUSDC() >= expectedUSDC);
    }
    
    function test_DepositETH_ExceedBankCap_PreCheck() public {
        // Asumiendo que 1 ETH = 2000 USDC, 5000 ETH serían 10M USDC (BANK_CAP).
        // Usamos 5001 ETH para asegurar que falle el pre-check.
        uint256 ethAmount = 5001 ether; 
        
        vm.startPrank(user1);
        // El pre-comprobación del cap debe fallar
        // El cálculo del cap debería ser: 5001 * 2000 * 10^6 = 10002000 * 10^6
        uint256 expectedTotal = 10002000 * 10**6; 
        
        vm.expectRevert(abi.encodeWithSignature("KipuBank_BankCapExceeded(uint256,uint256)", BANK_CAP, expectedTotal));
        kipuBank.depositETHAndSwapToUSDC{value: ethAmount}(
            1, 
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_DepositETH_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("KipuBank_ZeroAmount()"));
        kipuBank.depositETHAndSwapToUSDC{value: 0}(
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_DepositETH_DeadlinePassed() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("KipuBank_DeadlinePassed()"));
        kipuBank.depositETHAndSwapToUSDC{value: 1 ether}(
            1000,
            block.timestamp - 1
        );
        vm.stopPrank();
    }

    // ====================
    // ===== TESTS DEPÓSITO ERC20 =====
    // ====================

    function test_DepositERC20AndSwap_Success() public {
        uint256 testTokenAmount = 1 * 10**18; // 1 TEST token (18 decimals)
        // Cálculo: 1 TEST * 2 USDC/TEST = 2 USDC
        uint256 expectedUSDC = 2 * 10**6; // 2 USDC (6 decimals)
        
        vm.startPrank(user1);
        testToken.approve(address(kipuBank), testTokenAmount);
        uint256 minUSDCOut = expectedUSDC * 99 / 100; // 1% slippage
        kipuBank.depositERC20AndSwapToUSDC(
            address(testToken),
            testTokenAmount,
            minUSDCOut, 
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 userBalance = kipuBank.getUSDCBalance(user1);
        assertApproxEqAbs(userBalance, expectedUSDC, 1, "USDC balance incorrecto");
        assertEq(kipuBank.s_deposits(), 1);
        assertTrue(kipuBank.s_totalUSDC() >= minUSDCOut);
    }

    function test_DepositERC20_InsufficientOutput_Revert() public {
        uint256 testTokenAmount = 1 * 10**18;
        uint256 expectedUSDC = 2 * 10**6; // 2 USDC
        
        vm.startPrank(user1);
        testToken.approve(address(kipuBank), testTokenAmount);
        // Exigir una cantidad mayor a la que obtendremos (simula slippage extremo)
        uint256 highMinOut = expectedUSDC + 1; 
        
                vm.expectRevert("Insufficient output"); // agregado para probar
        kipuBank.depositERC20AndSwapToUSDC(
            address(testToken),
            testTokenAmount,
            highMinOut, 
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_DepositERC20_InvalidToken() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("KipuBank_InvalidAddress()"));
        kipuBank.depositERC20AndSwapToUSDC(
            address(0),
            1e18,
            1000,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_DepositERC20_USDCDirectly() public {
        vm.startPrank(user1);
        usdc.approve(address(kipuBank), 1000);
        
        vm.expectRevert(abi.encodeWithSignature("KipuBank_InvalidAddress()"));
        kipuBank.depositERC20AndSwapToUSDC(
            address(usdc), // Intenta swapear USDC a USDC (no permitido)
            1000,
            900,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }
    
    function test_DepositERC20_ExceedBankCap_PostCheck_RevertAndRefund() public {
        // Redesplegar KipuBank con un cap muy bajo
        uint256 customCap = 10 * 10**6; // 10 USDC
        uint256 depositAmount = 10 * 10**18; // 10 TEST
        uint256 expectedUSDC = 20 * 10**6; // 20 USDC

        vm.startPrank(admin);
        KipuBankV3 smallBank = new KipuBankV3(customCap, address(router), address(usdc), admin);
        vm.stopPrank();
        
        
        address[] memory path = new address[](2);
        path[0] = address(testToken);
        path[1] = address(usdc);

        vm.mockCall(
            address(router),
            abi.encodeWithSelector(IUniswapV2Router02.getAmountsOut.selector, depositAmount, path),
            abi.encode(new uint[](2)) 
        );

        vm.startPrank(user1);
        testToken.approve(address(smallBank), depositAmount);
        
        // Limpiar mocks para el swap real
        vm.clearMockedCalls(); 
        
        uint256 initialBalance = usdc.balanceOf(user1);
        
        // Esperar revert por cap excedido
        vm.expectRevert(
            abi.encodeWithSignature(
                "KipuBank_BankCapExceeded(uint256,uint256)",
                customCap,
                expectedUSDC
            )
        );

        // Ejecutar (debe revertir)
        smallBank.depositERC20AndSwapToUSDC(
            address(testToken),
            depositAmount,
            1,
            block.timestamp + 1 hours
        );
        
        // VERIFICACIÓN SIMPLIFICADA: El balance debe ser el mismo (revert deshace todo)
        assertEq(usdc.balanceOf(user1), initialBalance, "El balance cambio despues del revert");
        assertEq(smallBank.s_totalUSDC(), 0, "El cap no debe actualizarse");
        vm.stopPrank();
    }
    
    // ====================
    // ===== TESTS RETIRO =====
    // ====================

    function test_WithdrawUSDC_Success() public {
        uint256 depositAmount = 1000 * 10**6;
        
        // Primer deposito
        vm.startPrank(user1);
        usdc.approve(address(kipuBank), depositAmount);
        kipuBank.depositUSDC(depositAmount);
        
        // Registra balance antes del withdraw
        uint256 balanceBeforeWithdraw = usdc.balanceOf(user1);
        
        // El withdraw
        kipuBank.withdrawUSDC(depositAmount);
        vm.stopPrank();

        assertEq(kipuBank.getUSDCBalance(user1), 0);
        assertEq(kipuBank.s_totalUSDC(), 0);
        assertEq(kipuBank.s_withdrawals(), 1);
        assertEq(usdc.balanceOf(user1), balanceBeforeWithdraw + depositAmount);
    }

    function test_WithdrawUSDC_InsufficientBalance() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("KipuBank_InsufficientBalance(uint256,uint256)", 1000, 0));
        kipuBank.withdrawUSDC(1000);
        vm.stopPrank();
    }

    function test_WithdrawUSDC_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("KipuBank_ZeroAmount()"));
        kipuBank.withdrawUSDC(0);
        vm.stopPrank();
    }

    // ====================
    // ===== TESTS CONSULTAS =====
    // ====================

    function test_GetUSDCBalance() public {
        uint256 depositAmount = 500 * 10**6;
        
        vm.startPrank(user1);
        usdc.approve(address(kipuBank), depositAmount);
        kipuBank.depositUSDC(depositAmount);
        vm.stopPrank();

        assertEq(kipuBank.getUSDCBalance(user1), depositAmount);
        assertEq(kipuBank.getUSDCBalance(user2), 0);
    }

    function test_ContractUSDCBalance() public {
        uint256 depositAmount = 1000 * 10**6;
        
        vm.startPrank(user1);
        usdc.approve(address(kipuBank), depositAmount);
        kipuBank.depositUSDC(depositAmount);
        vm.stopPrank();

        assertEq(kipuBank.contractUSDCBalance(), depositAmount);
    }

    function test_AvailableCapacity() public {
        uint256 depositAmount = 500 * 10**6;
        
        vm.startPrank(user1);
        usdc.approve(address(kipuBank), depositAmount);
        kipuBank.depositUSDC(depositAmount);
        vm.stopPrank();

        assertEq(kipuBank.availableCapacity(), BANK_CAP - depositAmount);
    }

    function test_EstimateSwapOutput() public view {
        uint256 testAmount = 1 * 10**18; // 1 TEST token
        uint256 estimatedOutput = kipuBank.estimateSwapOutput(testAmount, address(testToken));
        
        // Output esperado: 2 USDC (2 * 10^6)
        assertEq(estimatedOutput, 2 * 10**6, "La estimacion de swap es incorrecta");
    }

    // ====================
    // ===== TESTS ADMIN =====
    // ====================

    function test_EmergencyWithdrawToken_Admin() public {
        // Deposit some USDC first
        uint256 depositAmount = 1000 * 10**6;
        vm.startPrank(user1);
        usdc.approve(address(kipuBank), depositAmount);
        kipuBank.depositUSDC(depositAmount);
        vm.stopPrank();

        // Retiro de emergencia como Admin
        uint256 contractBalance = usdc.balanceOf(address(kipuBank));
        vm.prank(admin);
        kipuBank.emergencyWithdrawToken(address(usdc), admin);

        // El balance inicial del admin es 0 (solo ETH), por lo que recibe el total del contrato
        assertEq(usdc.balanceOf(admin), contractBalance, "El admin no recibio el USDC de la emergencia");
        assertEq(usdc.balanceOf(address(kipuBank)), 0);
    }

    function test_EmergencyWithdrawETH_Admin() public {
        // Enviar ETH al contrato
        vm.deal(address(kipuBank), 5 ether);
        
        uint256 contractBalance = address(kipuBank).balance;
        uint256 adminBalanceBefore = address(admin).balance;
        
        vm.prank(admin);
        kipuBank.emergencyWithdrawToken(address(0), admin);

        // El balance del admin debe aumentar, y el contrato debe quedar sin ETH
        assertTrue(address(admin).balance > adminBalanceBefore, "El ETH no fue retirado");
        assertEq(address(kipuBank).balance, 0, "El ETH del contrato no se vacio");
    }

    function test_EmergencyWithdraw_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        kipuBank.emergencyWithdrawToken(address(usdc), user1);
    }

    // ====================
    // ===== TESTS INTEGRACIÓN =====
    // ====================

    function test_MultipleUsers_DepositsAndWithdrawals() public {
        uint256 user1Deposit = 300 * 10**6;
        uint256 user2Deposit = 700 * 10**6;
        
        // User1 deposit
        vm.startPrank(user1);
        usdc.approve(address(kipuBank), user1Deposit);
        kipuBank.depositUSDC(user1Deposit);
        vm.stopPrank();

        // User2 deposit  
        vm.startPrank(user2);
        usdc.approve(address(kipuBank), user2Deposit);
        kipuBank.depositUSDC(user2Deposit);
        vm.stopPrank();

        assertEq(kipuBank.getUSDCBalance(user1), user1Deposit);
        assertEq(kipuBank.getUSDCBalance(user2), user2Deposit);
        assertEq(kipuBank.s_totalUSDC(), user1Deposit + user2Deposit);
        assertEq(kipuBank.s_deposits(), 2);

        // User1 withdraw
        vm.startPrank(user1);
        kipuBank.withdrawUSDC(user1Deposit);
        vm.stopPrank();

        assertEq(kipuBank.getUSDCBalance(user1), 0);
        assertEq(kipuBank.s_totalUSDC(), user2Deposit);
        assertEq(kipuBank.s_withdrawals(), 1);
    }

    function test_BankCap_Respected() public {
        uint256 firstDeposit = BANK_CAP - 1000;
        uint256 secondDeposit = 2000; // Esto debería exceder el cap
        
        // Primer deposito (under cap)
        vm.startPrank(user1);
        usdc.mint(user1, firstDeposit);
        usdc.approve(address(kipuBank), firstDeposit);
        kipuBank.depositUSDC(firstDeposit);
        vm.stopPrank();

        // Segundo deposito (debe exceder el cap)
        vm.startPrank(user2);
        usdc.mint(user2, secondDeposit);
        usdc.approve(address(kipuBank), secondDeposit);
        
        vm.expectRevert(abi.encodeWithSignature("KipuBank_BankCapExceeded(uint256,uint256)", BANK_CAP, firstDeposit + secondDeposit));
        kipuBank.depositUSDC(secondDeposit);
        vm.stopPrank();
    }

    // ====================
    // ===== TESTS EDGE CASES =====
    // ====================

    function test_ReceiveETH() public {
        uint256 ethAmount = 1 ether;
        
        // Enviar ETH directamente al contract
        vm.prank(user1);
        (bool success, ) = payable(address(kipuBank)).call{value: ethAmount}("");
        require(success, "ETH transfer failed");
        
        assertEq(address(kipuBank).balance, ethAmount);
    }
}


