// Original procedural score for this game; no samples, recordings or downloads.
// Reproduce with: node tools/generate-game-music.mjs
import {mkdirSync, writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const directory = fileURLToPath(new URL('../assets/audio/', import.meta.url));
mkdirSync(directory, {recursive:true});
const rate = 22050, duration = 32, frames = rate * duration;
const hz = midi => 440 * Math.pow(2, (midi - 69) / 12);
function score(name, battle) {
  const samples = new Float64Array(frames);
  const melody = battle ? [62,69,71,69,66,64,66,69,74,71,69,66,64,66,62,69]
    : [62,66,69,71,69,66,64,62,59,62,64,66,69,66,64,62];
  function note(at, pitch, length, gain, pluck = true) {
    const frequency = hz(pitch), count = Math.floor(length * rate);
    for (let i = 0; i < count; i++) {
      const t = i / rate;
      const release = Math.pow(Math.max(0, 1 - t / length), 2);
      const attack = 1 - Math.exp(-t * (pluck ? 100 : 7));
      const envelope = attack * release * Math.exp(-t * (pluck ? 1.3 : 0.08));
      let voice = 0;
      for (let harmonic = 1; harmonic <= (pluck ? 7 : 2); harmonic++) {
        voice += Math.sin(2 * Math.PI * frequency * harmonic * t) / Math.pow(harmonic, pluck ? 2 : 3);
      }
      samples[(Math.floor(at * rate) + i) % frames] += voice * envelope * gain;
    }
  }
  for (let i = 0; i < 32; i++) {
    const at = i + 0.25;
    note(at, melody[i % 16], 2.7, 0.22);
    note(at + 0.17, melody[i % 16], 2.3, 0.045); // quiet reflected pluck
    if (battle) note(i + 0.75, [50,57,59,57][i % 4], 0.65, 0.08);
  }
  const roots = battle ? [50,47,55,57] : [50,55,47,50];
  for (let bar = 0; bar < 8; bar++) {
    const root = roots[bar % 4];
    for (const interval of [0,7,12]) note(bar * 4, root + interval, 6, 0.07, false);
  }
  let peak = Math.max(...samples.subarray(0, 1));
  for (const value of samples) peak = Math.max(peak, Math.abs(value));
  const pcm = Buffer.alloc(frames * 2);
  let energy = 0;
  for (let i = 0; i < frames; i++) {
    const value = samples[i] / peak * 0.28;
    energy += value * value;
    pcm.writeInt16LE(Math.round(value * 32767), i * 2);
  }
  const header = Buffer.alloc(44);
  header.write('RIFF'); header.writeUInt32LE(36 + pcm.length, 4); header.write('WAVEfmt ', 8);
  header.writeUInt32LE(16,16); header.writeUInt16LE(1,20); header.writeUInt16LE(1,22);
  header.writeUInt32LE(rate,24); header.writeUInt32LE(rate*2,28); header.writeUInt16LE(2,32); header.writeUInt16LE(16,34);
  header.write('data',36); header.writeUInt32LE(pcm.length,40);
  const bytes = Buffer.concat([header,pcm]);
  writeFileSync(directory + name + '.wav', bytes);
  return {name:name+'.wav', seconds:duration, sample_rate:rate, channels:1, bits:16, peak:0.28,
    rms:Math.sqrt(energy/frames), seam_step:Math.abs(pcm.readInt16LE(0)-pcm.readInt16LE(pcm.length-2))/32768,
    sha256:createHash('sha256').update(bytes).digest('hex')};
}
const tracks = [score('village_loop',false),score('battle_loop',true)];
writeFileSync(directory+'SOURCE.json',JSON.stringify({origin:'Original synthesized score created for 疯狂修仙，中; no third-party audio samples.',
  generator:'tools/generate-game-music.mjs',license:'Project-original audio; distributed with the game.',tracks},null,2)+'\n');
console.log(JSON.stringify(tracks));
