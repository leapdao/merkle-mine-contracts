pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";

/**
 * @title MerkleMine
 * @dev Token distribution based on providing Merkle proofs of inclusion in genesis state to generate allocation
 */
contract MerkleMine {
  using SafeMath for uint256;

  // ERC20 token being distributed
  ERC20 public token;
  // Merkle root representing genesis state which encodes token recipients
  bytes32 public genesisRoot;
  // Total amount of tokens that can be generated
  uint256 public totalGenesisTokens;
  // Total number of recipients included in genesis state
  uint256 public totalGenesisRecipients;

  // Start block where a third party caller (not the recipient) can generate and split the allocation with the recipient
  // As the current block gets closer to `callerAllocationEndBlock`, the caller receives a larger precentage of the allocation
  uint256 public callerAllocationStartBlock;
  // From this block onwards, a third party caller (not the recipient) can generate and claim the recipient's full allocation
  uint256 public callerAllocationEndBlock;

  // Track the already generated allocations for recipients
  mapping (address => bool) public generated;

  // Check that a recipient's allocation has not been generated
  modifier notGenerated(address _recipient) {
      require(!generated[_recipient]);
      _;
  }

  // Check that the generation period is started
  modifier isStarted() {
      require(totalGenesisTokens > 0);
      _;
  }

  // Check that the generation period is not started
  modifier isNotStarted() {
      require(totalGenesisTokens == 0);
      _;
  }

  event Generate(address indexed _recipient, address indexed _caller, uint256 _recipientTokenAmount, uint256 _callerTokenAmount, uint256 _block);

  /**
   * @dev MerkleMine constructor
   * @param _token ERC20 token being distributed
   * @param _genesisRoot Merkle root representing genesis state which encodes token recipients
   * @param _totalGenesisRecipients Total number of recipients included in genesis state
   * @param _callerAllocationStartBlock Start block where a third party caller (not the recipient) can generate and split the allocation with the recipient
   * @param _callerAllocationEndBlock From this block onwards, a third party caller (not the recipient) can generate and claim the recipient's full allocation
   */
  constructor(address _token, bytes32 _genesisRoot, uint256 _totalGenesisRecipients, uint256 _callerAllocationStartBlock, uint256 _callerAllocationEndBlock) public {
    // Address of token contract must not be null
    require(_token != address(0));
    // Number of recipients must be non-zero
    require(_totalGenesisRecipients > 0);
    // Start block for caller allocation must be after current block
    require(_callerAllocationStartBlock > block.number);
    // End block for caller allocation must be after caller allocation start block
    require(_callerAllocationEndBlock > _callerAllocationStartBlock);

    token = ERC20(_token);
    genesisRoot = _genesisRoot;
    totalGenesisRecipients = _totalGenesisRecipients;
    callerAllocationStartBlock = _callerAllocationStartBlock;
    callerAllocationEndBlock = _callerAllocationEndBlock;
  }

  /**
   * @dev Start the generation period - first checks that this contract's balance is equal to `totalGenesisTokens`
   * The generation period must not already be started
   */
  function start() external isNotStarted {
    // Check that this contract has a sufficient balance for the generation period
    require(totalGenesisTokens == 0);
    require(token.balanceOf(this) > 0);
    totalGenesisTokens = token.balanceOf(this);
  }

  /**
   * @dev Generate a recipient's token allocation. Generation period must be started. Starting from `callerAllocationStartBlock`
   * a third party caller (not the recipient) can invoke this function to generate the recipient's token
   * allocation and claim a percentage of it. The percentage of the allocation claimed by the
   * third party caller is determined by how many blocks have elapsed since `callerAllocationStartBlock`.
   * After `callerAllocationEndBlock`, a third party caller can claim the full allocation
   * @param _recipient Recipient of token allocation
   * @param _merkleProof Proof of recipient's inclusion in genesis state Merkle root
   */
  function generate(address _recipient, bytes32[] _merkleProof) external isStarted notGenerated(_recipient) {
    // Check the Merkle proof
    bytes32 leaf = keccak256(abi.encodePacked(_recipient));

    // _merkleProof must prove inclusion of _recipient in the genesis state root
    require(verify(_merkleProof, genesisRoot, leaf));

    generated[_recipient] = true;

    address callerAddr = msg.sender;
    uint256 tokensPerAllocation = totalGenesisTokens.div(totalGenesisRecipients);

    if (callerAddr == _recipient) {
      // If the caller is the recipient, transfer the full allocation to the caller/recipient
      require(token.transfer(_recipient, tokensPerAllocation));

      emit Generate(_recipient, _recipient, tokensPerAllocation, 0, block.number);
    } else {
      // If the caller is not the recipient, the token allocation generation
      // can only take place if we are in the caller allocation period
      require(block.number >= callerAllocationStartBlock);

      uint256 callerTokenAmount = callerTokenAmountAtBlock(block.number);
      uint256 recipientTokenAmount = tokensPerAllocation.sub(callerTokenAmount);

      if (callerTokenAmount > 0) {
          require(token.transfer(callerAddr, callerTokenAmount));
      }

      if (recipientTokenAmount > 0) {
          require(token.transfer(_recipient, recipientTokenAmount));
      }

      emit Generate(_recipient, callerAddr, recipientTokenAmount, callerTokenAmount, block.number);
    }
  }

  /**
   * @dev Return the amount of tokens claimable by a third party caller when generating a recipient's token allocation at a given block
   * @param _blockNumber Block at which to compute the amount of tokens claimable by a third party caller
   */
  function callerTokenAmountAtBlock(uint256 _blockNumber) public view returns (uint256) {
    uint256 tokensPerAllocation = totalGenesisTokens.div(totalGenesisRecipients);
    if (_blockNumber < callerAllocationStartBlock) {
      // If the block is before the start of the caller allocation period, the third party caller can claim nothing
      return 0;
    } else if (_blockNumber >= callerAllocationEndBlock) {
      // If the block is at or after the end block of the caller allocation period, the third party caller can claim everything
      return tokensPerAllocation;
    } else {
      // During the caller allocation period, the third party caller can claim an increasing percentage
      // of the recipient's allocation based on a linear curve - as more blocks pass in the caller allocation
      // period, the amount claimable by the third party caller increases linearly
      uint256 blocksSinceCallerAllocationStartBlock = _blockNumber.sub(callerAllocationStartBlock);
      uint256 callerAllocationPeriod = callerAllocationEndBlock.sub(callerAllocationStartBlock);
      return tokensPerAllocation.mul(blocksSinceCallerAllocationStartBlock).div(callerAllocationPeriod);
    }
  }

  /**
   * @dev Verifies a Merkle proof proving the existence of a leaf in a Merkle tree. Assumes that each pair of leaves
   * and each pair of pre-images are sorted.
   * @param proof Merkle proof containing sibling hashes on the branch from the leaf to the root of the Merkle tree
   * @param root Merkle root
   * @param leaf Leaf of Merkle tree
   */
  function verify(bytes32[] proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
    bytes32 computedHash = leaf;

    for (uint256 i = 0; i < proof.length; i++) {
      bytes32 proofElement = proof[i];

      if (computedHash < proofElement) {
        assembly {
          mstore(0, computedHash)
          mstore(0x20, proofElement)
          computedHash := keccak256(0, 0x40)
        }
      } else {
        assembly {
          mstore(0, proofElement)
          mstore(0x20, computedHash)
          computedHash := keccak256(0, 0x40)
        }
      }
    }

    // Check if the computed hash (root) is equal to the provided root
    return computedHash == root;
  }
}
