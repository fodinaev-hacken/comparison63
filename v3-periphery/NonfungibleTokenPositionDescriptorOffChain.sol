// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol';

import './interfaces/INonfungibleTokenPositionDescriptor.sol';

/// @title Describes NFT token positions
contract NonfungibleTokenPositionDescriptorOffChain is INonfungibleTokenPositionDescriptor, Initializable {
    using StringsUpgradeable for uint256;

    string private _baseTokenURI;

    function initialize(string calldata baseTokenURI) external initializer {
        _baseTokenURI = baseTokenURI;
    }

    /// @inheritdoc INonfungibleTokenPositionDescriptor
    function tokenURI(INonfungiblePositionManager, uint256 tokenId)
        external
        view
        override
        returns (string memory)
    {
        return bytes(_baseTokenURI).length > 0 ? string(abi.encodePacked(_baseTokenURI, tokenId.toString())) : "";
    }
}
