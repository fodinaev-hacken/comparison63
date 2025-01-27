// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

interface IMorphexV3LmPoolDeveloper {
    function parameters() external view returns (address pool, address masterChef);
}
