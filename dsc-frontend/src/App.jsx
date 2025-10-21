// src/App.jsx
import { useState } from 'react';
import { ethers } from 'ethers';
import './App.css';
import DscEngineComponent from './components/DSCEngineComponent'; // Import the new component

function App() {
  const [account, setAccount] = useState(null);
  const [signer, setSigner] = useState(null);

  const connectWallet = async () => {
    if (window.ethereum) {
      try {
        const provider = new ethers.BrowserProvider(window.ethereum);
        const accounts = await provider.send('eth_requestAccounts', []);
        const signer = await provider.getSigner();
        
        setAccount(accounts[0]);
        setSigner(signer);
      } catch (error) {
        console.error("Error connecting wallet:", error);
        alert("Failed to connect wallet. See console for details.");
      }
    } else {
      alert('Please install MetaMask!');
    }
  };

  const getShortAddress = (address) => {
    if (!address) return "";
    return `${address.slice(0, 6)}...${address.slice(-4)}`;
  }

  return (
    <div className="App">
      <header className="App-header">
        <h1>ZK Stablecoin Frontend</h1>
        <button onClick={connectWallet} className="wallet-button">
          {account ? `Connected: ${getShortAddress(account)}` : 'Connect Wallet'}
        </button>
      </header>
      
      <main>
        {signer && account ? (
          <DscEngineComponent signer={signer} account={account} />
        ) : (
          <p>Please connect your wallet to continue.</p>
        )}
      </main>
    </div>
  );
}

export default App;