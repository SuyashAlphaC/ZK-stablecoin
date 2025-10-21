

import { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import { DSC_ENGINE_ADDRESS, WETH_ADDRESS, DSC_TOKEN_ADDRESS } from '../constants';
import DSCEngineABI from '../abi/DSCEngine.json';
import DSCABI from '../abi/DecentralizedStableCoin.json';
import ERC20ABI from '../abi/ERC20.json';

// Helper component for managing loading states on buttons
const ActionButton = ({ isSubmitting, text }) => (
    <button type="submit" disabled={isSubmitting}>
        {isSubmitting ? 'Processing...' : text}
    </button>
);

function DSCEngineComponent({ signer, account }) {
    // --- State Variables ---
    const [dscEngineContract, setDscEngineContract] = useState(null);
    const [wethContract, setWethContract] = useState(null);
    const [dscContract, setDscContract] = useState(null);
    const [activeTab, setActiveTab] = useState('mint');
    const [isSubmitting, setIsSubmitting] = useState(false);
    
    // Position Info
    const [positionInfo, setPositionInfo] = useState({ collateralValue: '0.00', dscMinted: '0.00' });
    const [walletBalances, setWalletBalances] = useState({ weth: '0.00', dsc: '0.00' });

    // --- Contract Initialization ---
    useEffect(() => {
        if (signer) {
            setDscEngineContract(new ethers.Contract(DSC_ENGINE_ADDRESS, DSCEngineABI, signer));
            setWethContract(new ethers.Contract(WETH_ADDRESS, ERC20ABI, signer));
            setDscContract(new ethers.Contract(DSC_TOKEN_ADDRESS, DSCABI, signer));
        }
    }, [signer]);

    // --- Data Fetching ---
    const fetchAllInfo = async () => {
        if (!dscEngineContract || !wethContract || !dscContract || !account) return;
        try {
            // Fetch position info from DSCEngine
            const [totalDscMinted, collateralValueInUsd] = await dscEngineContract.getAccountInformation(account);
            setPositionInfo({
                dscMinted: ethers.formatEther(totalDscMinted),
                collateralValue: ethers.formatUnits(collateralValueInUsd, 18),
            });
            // Fetch wallet balances
            const wethBalance = await wethContract.balanceOf(account);
            const dscBalance = await dscContract.balanceOf(account);
            setWalletBalances({
                weth: ethers.formatEther(wethBalance),
                dsc: ethers.formatEther(dscBalance),
            });
        } catch (error) {
            console.error("Failed to fetch account info:", error);
        }
    };

    useEffect(() => {
        fetchAllInfo();
    }, [dscEngineContract, account]);

    // --- ZK Proof Helper ---
    const fetchProof = async (total_dsc_minted, collateral_value_in_usd) => {
        const body = {
            total_dsc_minted: total_dsc_minted.toString(),
            collateral_value_in_usd: collateral_value_in_usd.toString(),
        };
        console.log("Requesting proof with:", body);
        const response = await fetch('http://localhost:3001/generate-proof', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });
        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Failed to generate proof.');
        }
        const { proof } = await response.json();
        console.log("Proof received!");
        return proof;
    };
    
    // --- Generic Transaction Handler ---
    const handleTransaction = async (action, form) => {
        setIsSubmitting(true);
        try {
            await action();
            alert("Transaction successful!");
            fetchAllInfo();
            form.reset();
        } catch (error) {
            console.error("Transaction failed:", error);
            alert(`Transaction failed: ${error.message}`);
        }
        setIsSubmitting(false);
    };

    // --- Form Submit Handlers ---
    const handleDepositAndMint = (e) => {
        e.preventDefault();
        const form = e.target;
        const { collateralAmount, dscToMint } = Object.fromEntries(new FormData(form));
        
        handleTransaction(async () => {
            const collateralWei = ethers.parseEther(collateralAmount);
            const dscWei = ethers.parseEther(dscToMint);
            console.log("Approving WETH transfer...");
            const approveTx = await wethContract.approve(DSC_ENGINE_ADDRESS, collateralWei);
            await approveTx.wait(1);
            console.log("Approval successful!");

           console.log("Calculating expected state for proof...");
            const [initialDscMinted, initialCollateralValue] = await dscEngineContract.getAccountInformation(account);
            console.log("Initial DSC Minted:", ethers.formatEther(initialDscMinted));
            const collateralValue = await dscEngineContract.getUsdValue(WETH_ADDRESS, collateralWei);

            const expectedTotalDscMinted = BigInt(initialDscMinted) + BigInt(dscWei);
            const expectedCollateralValueInUsd = BigInt(initialCollateralValue) + BigInt(collateralValue);
            console.log("Expected Total DSC Minted:", ethers.formatEther(expectedTotalDscMinted));

            const proof = await fetchProof(expectedTotalDscMinted,expectedCollateralValueInUsd);
            console.log("Proof received from backend!");

            // Step 4: Call the contract with the proof
            console.log("Depositing collateral and minting DSC with ZK proof...");
            const tx = await dscEngineContract.depositCollateralAndMintDscWithZK(
                WETH_ADDRESS,
                collateralWei,
                dscWei,
                proof
            );
            await tx.wait(1);
            // await (await dscEngineContract.depositCollateralAndMintDscWithZK(WETH_ADDRESS, collateralWei, dscWei, proof, { gasLimit: 3000000 })).wait(1);
        }, form);
    };

    const handleRedeemAndBurn = (e) => {
        e.preventDefault();
        const form = e.target;
        const { collateralAmount, dscToBurn } = Object.fromEntries(new FormData(form));
        
        handleTransaction(async () => {
            const collateralWei = ethers.parseEther(collateralAmount);
            const dscWei = ethers.parseEther(dscToBurn);

            await (await dscContract.approve(DSC_ENGINE_ADDRESS, dscWei)).wait(1);

            const [minted, collateral] = await dscEngineContract.getAccountInformation(account);
            const collateralValueToRedeem = await dscEngineContract.getUsdValue(WETH_ADDRESS, collateralWei);
            
            const proof = await fetchProof(BigInt(minted) - BigInt(dscWei), BigInt(collateral) - BigInt(collateralValueToRedeem));

            await (await dscEngineContract.redeemCollateralForDscWithZK(WETH_ADDRESS, collateralWei, dscWei, proof, { gasLimit: 3000000 })).wait(1);
        }, form);
    };

    const handleWithdraw = (e) => {
        e.preventDefault();
        const form = e.target;
        const { collateralAmount } = Object.fromEntries(new FormData(form));

        handleTransaction(async () => {
            const amountWei = ethers.parseEther(collateralAmount);

            const [minted, collateral] = await dscEngineContract.getAccountInformation(account);
            const collateralValueToRedeem = await dscEngineContract.getUsdValue(WETH_ADDRESS, amountWei);

            const proof = await fetchProof(minted, BigInt(collateral) - BigInt(collateralValueToRedeem));

            await (await dscEngineContract.redeemCollateralWithZK(WETH_ADDRESS, amountWei, proof, { gasLimit: 3000000 })).wait(1);
        }, form);
    };

    const handleBurn = (e) => {
        e.preventDefault();
        const form = e.target;
        const { dscToBurn } = Object.fromEntries(new FormData(form));

        handleTransaction(async () => {
            const amountWei = ethers.parseEther(dscToBurn);

            await (await dscContract.approve(DSC_ENGINE_ADDRESS, amountWei)).wait(1);
            
            const [minted, collateral] = await dscEngineContract.getAccountInformation(account);
            const proof = await fetchProof(BigInt(minted) - BigInt(amountWei), collateral);

            await (await dscEngineContract.burnDscWithZK(amountWei, proof, { gasLimit: 3000000 })).wait(1);
        }, form);
    };

    // --- Render Logic ---
    return (
        <div className="card">
            <h2>Your Position</h2>
            <div className="info-grid">
                <span>Collateral Value:</span><span>${parseFloat(positionInfo.collateralValue).toFixed(2)}</span>
                <span>DSC Minted:</span><span>{parseFloat(positionInfo.dscMinted).toFixed(2)} DSC</span>
                <span>WETH Balance:</span><span>{parseFloat(walletBalances.weth).toFixed(4)} WETH</span>
                <span>DSC Balance:</span><span>{parseFloat(walletBalances.dsc).toFixed(2)} DSC</span>
            </div>

            <div className="tabs">
                <button className={`tab-button ${activeTab === 'mint' ? 'active' : ''}`} onClick={() => setActiveTab('mint')}>Mint</button>
                <button className={`tab-button ${activeTab === 'redeem' ? 'active' : ''}`} onClick={() => setActiveTab('redeem')}>Redeem</button>
                <button className={`tab-button ${activeTab === 'burn' ? 'active' : ''}`} onClick={() => setActiveTab('burn')}>Burn</button>
            </div>

            {activeTab === 'mint' && (
                <div className="tab-content active">
                    <form onSubmit={handleDepositAndMint}>
                        <h3>Deposit Collateral & Mint DSC</h3>
                        <div className="form-group"><label>WETH to Deposit</label><input name="collateralAmount" type="text" placeholder="e.g., 1.0" required /></div>
                        <div className="form-group"><label>DSC to Mint</label><input name="dscToMint" type="text" placeholder="e.g., 1500" required /></div>
                        <ActionButton isSubmitting={isSubmitting} text="Deposit & Mint" />
                    </form>
                    
                </div>
            )}

            {activeTab === 'redeem' && (
                <div className="tab-content active">
                    <form onSubmit={handleRedeemAndBurn}>
                        <h3>Redeem Collateral & Burn DSC</h3>
                        <div className="form-group"><label>WETH to Redeem</label><input name="collateralAmount" type="text" placeholder="e.g., 0.5" required /></div>
                        <div className="form-group"><label>DSC to Burn</label><input name="dscToBurn" type="text" placeholder="e.g., 750" required /></div>
                        <ActionButton isSubmitting={isSubmitting} text="Redeem & Burn" />
                    </form>
                    <div className="divider"></div>
                    <form onSubmit={handleWithdraw}>
                        <h3>Withdraw Collateral Only</h3>
                        <div className="form-group"><label>WETH to Withdraw</label><input name="collateralAmount" type="text" placeholder="e.g., 0.1" required /></div>
                        <ActionButton isSubmitting={isSubmitting} text="Withdraw Collateral" />
                    </form>
                </div>
            )}

            {activeTab === 'burn' && (
                <div className="tab-content active">
                    <form onSubmit={handleBurn}>
                        <h3>Burn DSC to Repay Debt</h3>
                        <div className="form-group"><label>DSC to Burn</label><input name="dscToBurn" type="text" placeholder="e.g., 100" required /></div>
                        <ActionButton isSubmitting={isSubmitting} text="Burn DSC" />
                    </form>
                </div>
            )}
        </div>
    );
}

export default DSCEngineComponent;

