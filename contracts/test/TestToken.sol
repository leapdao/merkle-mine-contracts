pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20Mintable.sol";

contract TestToken is ERC20Mintable {
    string public name = "Test Token";
    uint8 public decimals = 18;
}
