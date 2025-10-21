// import express from 'express';
// import cors from 'cors';
// import { exec } from 'child_process';
// import { ethers } from 'ethers';
// import path from 'path';
// import { fileURLToPath } from 'url';

// // --- Server Setup ---
// const app = express();
// app.use(cors()); // Allow requests from your frontend
// app.use(express.json());

// const PORT = 3001; // We'll run the backend on a different port

// // --- Helper for file paths ---
// const __filename = fileURLToPath(import.meta.url);
// const __dirname = path.dirname(__filename);

// // --- API Endpoint for Proof Generation ---
// app.post('/generate-proof', (req, res) => {
//     const { total_dsc_minted, collateral_value_in_usd } = req.body;

//     // Basic validation
//     if (!total_dsc_minted || !collateral_value_in_usd) {
//         return res.status(400).json({ error: 'Missing required inputs.' });
//     }

//     console.log(`Received request to generate proof for:`);
//     console.log(`  Total DSC Minted: ${total_dsc_minted}`);
//     console.log(`  Collateral Value (USD): ${collateral_value_in_usd}`);

//     // Construct the path to the proof generation script relative to this server file
//     const scriptPath = path.join(__dirname, '../contract/js-scripts/generateProof.ts');

//     // Execute the TypeScript proof generation script using tsx
//     const command = `npx tsx ${scriptPath} ${total_dsc_minted} ${collateral_value_in_usd}`;

//     exec(command, (error, stdout, stderr) => {
//         if (error) {
//             console.error(`Proof generation script failed: ${error.message}`);
//             return res.status(500).json({ error: 'Proof generation failed.', details: stderr });
//         }

//         try {
//             // The script outputs an ABI-encoded hex string. We need to decode it.
//             const encodedOutput = stdout.trim();
//             const [proof] = ethers.AbiCoder.defaultAbiCoder().decode(['bytes', 'bytes32[]'], encodedOutput);

//             console.log("Successfully generated and decoded proof.");
            
//             // Send the raw proof bytes back to the frontend
//             res.json({ proof: proof });

//         } catch (decodeError) {
//             console.error(`Failed to decode proof script output: ${decodeError}`);
//             res.status(500).json({ error: 'Failed to process proof.', details: stdout });
//         }
//     });
// });

// // --- Start the Server ---
// app.listen(PORT, () => {
//     console.log(`✅ ZK Proof Generation Server is running on http://localhost:${PORT}`);
// });

// backend/server.js
import express from 'express';
import cors from 'cors';
import { ethers } from 'ethers';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs';
import { Noir } from '@noir-lang/noir_js';
import { UltraHonkBackend } from '@aztec/bb.js';

// --- Server Setup ---
const app = express();
app.use(cors());
app.use(express.json());
const PORT = 3001;

// --- Helper for file paths ---
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// --- Load Noir Circuit ---
// This path is now relative to the backend/server.js file
const circuitPath = path.resolve(__dirname, '../circuit/target/circuit.json');
const circuit = JSON.parse(fs.readFileSync(circuitPath, 'utf8'));

// --- Initialize Noir and Barretenberg Backend ---
// We can initialize these once when the server starts
const noir = new Noir(circuit);
const backend = new UltraHonkBackend(circuit.bytecode, { threads: 1 });
console.log("✅ Noir backend initialized successfully.");

// --- API Endpoint for Proof Generation ---
app.post('/generate-proof', async (req, res) => {
    const { total_dsc_minted, collateral_value_in_usd } = req.body;

    if (!total_dsc_minted || !collateral_value_in_usd) {
        return res.status(400).json({ error: 'Missing required inputs.' });
    }

    console.log(`Received request to generate proof for:`);
    console.log(`  Total DSC Minted: ${total_dsc_minted}`);
    console.log(`  Collateral Value (USD): ${collateral_value_in_usd}`);

    try {
        const inputs = {
            total_dsc_minted,
            collateral_value_in_usd,
        };

        // Generate the witness
        console.log("Generating witness...");
        const { witness } = await noir.execute(inputs);
        console.log("Witness generated.");

        // Generate the proof
        console.log("Generating proof...");
        const { proof, publicInputs } = await backend.generateProof(witness, { keccak: true });
        console.log("Proof generated successfully.");

        // IMPORTANT: The contract verifier expects the proof as raw bytes ('0x...' string).
        // We will send this back directly.
        const proofAsHex = `0x${Buffer.from(proof).toString('hex')}`;

        res.json({ proof: proofAsHex });

    } catch (error) {
        console.error("Error during proof generation:", error);
        res.status(500).json({ error: 'Proof generation failed.', details: error.message });
    }
});

// --- Start the Server ---
app.listen(PORT, () => {
    console.log(`✅ ZK Proof Generation Server is running on http://localhost:${PORT}`);
});