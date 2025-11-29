// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../src/KipuBankV3.sol";

contract DeployKipuBankV3 is Script {

    function run() external {
        // Cargar clave privada desde .env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Parámetros
        uint256 bankCap = 10_000_000 * 10**6; // 10M USDC
        //address router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; // este no existe en uniswapV2
        address router = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;   // Router UNISWAP-V2 compatible en Sepolia
        address usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        address admin = vm.addr(deployerPrivateKey);

        // Deployar contrato
        KipuBankV3 kipu = new KipuBankV3(
            bankCap,
            router,
            usdc,
            admin
        );

        console2.log("KipuBankV3 deployed at:", address(kipu));

        vm.stopBroadcast();
    }
}
