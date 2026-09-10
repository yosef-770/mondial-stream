/**
 * הודעות "שידור כבוי" לשלוחות kanbet / kan11.
 * הרצה: node /srv/mondial-stream/scripts/generate-live-audio.mjs
 */
import { execSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { GoogleGenAI } from "/srv/virtual-mail/node_modules/@google/genai/dist/node/index.mjs";

const __dir = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(__dir, "../freeswitch/sounds/he/live");

const DEFAULT_MODELS = ["gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"];
const MAX_ATTEMPTS = 6;

function loadVirtualMailEnv() {
  for (const line of readFileSync("/srv/virtual-mail/.env.local", "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq <= 0) continue;
    const key = trimmed.slice(0, eq).trim();
    const val = trimmed.slice(eq + 1).trim();
    if (!process.env[key]) process.env[key] = val;
  }
}

function buildWavBuffer(pcmData, channels = 1, rate = 24000, sampleWidth = 2) {
  const byteRate = rate * channels * sampleWidth;
  const blockAlign = channels * sampleWidth;
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcmData.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(rate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(sampleWidth * 8, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcmData.length, 40);
  return Buffer.concat([header, pcmData]);
}

function decodeAudioData(data) {
  if (Buffer.isBuffer(data)) return data;
  if (typeof data === "string") return Buffer.from(data, "base64");
  return Buffer.from(data);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function synthesizeHebrewWav(text) {
  const apiKey = process.env.GEMINI_API_KEY?.trim();
  if (!apiKey) throw new Error("GEMINI_API_KEY חסר");

  const trimmed = text.trim().slice(0, 4800);
  const voiceName = process.env.GEMINI_TTS_VOICE?.trim() || "Charon";
  const languageCode = process.env.GEMINI_TTS_LANGUAGE?.trim() || "he-IL";
  const ai = new GoogleGenAI({ apiKey });
  const prompt = `TTS the following Hebrew text exactly as written: ${trimmed}`;

  let lastReason = "unknown";
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
    const model = DEFAULT_MODELS[Math.min(attempt, DEFAULT_MODELS.length - 1)];
    try {
      const response = await ai.models.generateContent({
        model,
        contents: [{ parts: [{ text: prompt }] }],
        config: {
          responseModalities: ["AUDIO"],
          speechConfig: {
            languageCode,
            voiceConfig: { prebuiltVoiceConfig: { voiceName } },
          },
        },
      });
      const candidate = response.candidates?.[0];
      const data = candidate?.content?.parts?.[0]?.inlineData?.data;
      lastReason = candidate?.finishReason || "unknown";
      if (!data) {
        await sleep(1500 * (attempt + 1));
        continue;
      }
      const pcmBuffer = decodeAudioData(data);
      if (pcmBuffer.length === 0) throw new Error("gemini_empty_audio");
      return buildWavBuffer(pcmBuffer);
    } catch (error) {
      if (attempt < MAX_ATTEMPTS - 1) {
        await sleep(1500 * (attempt + 1));
        continue;
      }
      throw error;
    }
  }
  throw new Error(`gemini_tts_failed:${lastReason}`);
}

function toTelephonyWav(inputPath, outputPath) {
  execSync(
    `ffmpeg -y -hide_banner -loglevel error -i "${inputPath}" -ar 8000 -ac 1 -acodec pcm_s16le "${outputPath}"`,
    { stdio: "inherit" },
  );
}

async function writeClip(name, text) {
  const rawPath = join(OUT_DIR, `${name}-24k.wav`);
  const outPath = join(OUT_DIR, `${name}.wav`);
  console.log(`[generate] ${name}...`);
  writeFileSync(rawPath, await synthesizeHebrewWav(text));
  toTelephonyWav(rawPath, outPath);
  execSync(`rm -f "${rawPath}"`);
  console.log(`[generate] wrote ${outPath}`);
}

loadVirtualMailEnv();
mkdirSync(OUT_DIR, { recursive: true });

await writeClip(
  "off-kanbet",
  "שידור רשת בית אינו פעיל כרגע. נסו שוב מאוחר יותר.",
);
await writeClip(
  "off-kan11",
  "שידור כאן 11 אינו פעיל כרגע. נסו שוב מאוחר יותר.",
);
console.log("[generate] done.");
