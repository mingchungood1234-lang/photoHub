/**
 * SERVER-SIDE PROXY TRANSCODING SERVICE (`sharp` + `ffmpeg`)
 *
 * Where this belongs: `src/services/proxyService.js` (Service Layer).
 * Called by:
 *   - `src/controllers/proxyController.js` (`generateProxy` -> compresses images/videos on server under `.proxies/`)
 *   - `src/controllers/photoController.js` (`isVideoFilename` -> checks whether a filename is a video)
 * How fallback works: If neither `sharp` nor `ffmpeg` is installed, throws HTTP `501` with
 * `fallbackToClient: true` so the Android/iOS app automatically compresses locally instead.
 */

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');

let sharpModule = null;
try {
  // Optional dependency; gracefully falls back if unavailable
  sharpModule = require('sharp');
  if (sharpModule && typeof sharpModule.cache === 'function') {
    // Disable libvips file-descriptor cache so deleted/moved files never trigger EBUSY on Windows
    sharpModule.cache(false);
  }
} catch {
  sharpModule = null;
}

const VIDEO_EXTENSIONS = new Set(['.mov', '.mp4', '.m4v', '.3gp', '.avi']);

let cachedFfmpegAvailable = null;

function createConcurrencyGate(maxConcurrent) {
  let active = 0;
  const queue = [];
  return async function runLimited(fn) {
    if (active >= maxConcurrent) {
      await new Promise((resolve) => queue.push(resolve));
    }
    active += 1;
    try {
      return await fn();
    } finally {
      active -= 1;
      const next = queue.shift();
      if (next) next();
    }
  };
}

const sharpGate = createConcurrencyGate(2);
const ffmpegGate = createConcurrencyGate(1);

function isVideoFilename(name = '') {
  return VIDEO_EXTENSIONS.has(path.extname(String(name)).toLowerCase());
}

async function hasFfmpeg() {
  if (cachedFfmpegAvailable !== null) {
    return cachedFfmpegAvailable;
  }
  cachedFfmpegAvailable = await new Promise((resolve) => {
    execFile('ffmpeg', ['-version'], { timeout: 3000 }, (err) => {
      resolve(!err);
    });
  });
  return cachedFfmpegAvailable;
}

async function getCapabilities() {
  const ffmpeg = await hasFfmpeg();
  return {
    sharp: Boolean(sharpModule),
    ffmpeg,
    available: Boolean(sharpModule) || ffmpeg,
  };
}

function runFfmpeg(args, timeoutMs = 120000) {
  return ffmpegGate(
    () =>
      new Promise((resolve, reject) => {
        execFile('ffmpeg', args, { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 }, (err, _stdout, stderr) => {
          if (err) {
            const msg = stderr ? String(stderr).slice(-300) : err.message;
            const wrapped = new Error(`ffmpeg failed: ${msg}`);
            wrapped.cause = err;
            reject(wrapped);
            return;
          }
          resolve();
        });
      })
  );
}

async function computeFileSha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

function makeFallbackError(message) {
  const err = new Error(message);
  err.statusCode = 501;
  err.fallbackToClient = true;
  return err;
}

async function generateImageProxyWithSharp(sourcePath, maxPixelSize, qualityPercent) {
  if (!sharpModule) {
    throw makeFallbackError('sharp is not available on this server');
  }
  const metadata = await sharpModule(sourcePath).metadata();
  const longest = Math.max(metadata.width || 0, metadata.height || 0);
  let targetMax = maxPixelSize > 0 ? maxPixelSize : 1440;
  if (maxPixelSize <= 0) {
    if (longest > 4096) targetMax = 1920;
    else if (longest > 2048) targetMax = 1440;
    else if (longest > 1280) targetMax = 1024;
    else if (longest > 0) targetMax = Math.max(640, Math.round(longest * 0.75));
  } else if (longest > 0) {
    targetMax = Math.min(longest, maxPixelSize);
  }

  return sharpGate(() =>
    sharpModule(sourcePath)
      .rotate()
      .resize({
        width: targetMax,
        height: targetMax,
        fit: 'inside',
        withoutEnlargement: true,
      })
      .jpeg({
        quality: qualityPercent,
        mozjpeg: true,
      })
      .toBuffer()
  );
}

async function generateServerSideProxy({
  sourcePath,
  proxiesDir,
  masterHash,
  originalName,
  maxPixelSize = 0,
  quality = 0.72,
}) {
  const normMaster = String(masterHash || '').trim().toLowerCase();
  const qualityNum = Math.min(0.95, Math.max(0.3, Number(quality) || 0.72));
  const qualityPercent = Math.round(qualityNum * 100);
  const maxPx = Math.max(0, Number(maxPixelSize) || 0);

  await fsp.mkdir(proxiesDir, { recursive: true });

  if (isVideoFilename(originalName || sourcePath)) {
    if (!(await hasFfmpeg())) {
      throw makeFallbackError('ffmpeg is not installed on server to proxy videos');
    }

    const posterName = `${normMaster}.jpg`;
    const posterPath = path.join(proxiesDir, posterName);
    const posterTmp = `${posterPath}.tmp.jpg`;

    const videoName = `${normMaster}.mp4`;
    const videoPath = path.join(proxiesDir, videoName);
    const videoTmp = `${videoPath}.tmp.mp4`;

    try {
      // Extract a compressed 800px poster frame quickly
      try {
        await runFfmpeg([
          '-y',
          '-ss', '00:00:00.5',
          '-i', sourcePath,
          '-frames:v', '1',
          '-vf', "scale='min(800,iw)':-2",
          '-q:v', '4',
          posterTmp,
        ], 30000);
      } catch {
        // Retry at t=0 for ultra-short clips (< 0.5s)
        await runFfmpeg([
          '-y',
          '-i', sourcePath,
          '-frames:v', '1',
          '-vf', "scale='min(800,iw)':-2",
          '-q:v', '4',
          posterTmp,
        ], 30000).catch(() => {});
      }

      // Encode lightweight compressed H.264 + AAC proxy MP4 honoring user's resolution/detail preference
      const targetHeight =
        maxPx >= 2400 ? 1440 :
        maxPx >= 1800 ? 1080 :
        maxPx >= 1100 ? 720 :
        maxPx > 0 ? 480 :
        qualityNum < 0.59 ? 540 : 720;
      const crfVal = qualityNum >= 0.78 ? '24' : qualityNum < 0.59 ? '31' : '28';
      const videoScaleFilter = `scale='if(gte(iw,ih),-2,min(${targetHeight},iw))':'if(gte(iw,ih),min(${targetHeight},ih),-2)'`;

      await runFfmpeg([
        '-y',
        '-i', sourcePath,
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-crf', crfVal,
        '-pix_fmt', 'yuv420p',
        '-vf', videoScaleFilter,
        '-c:a', 'aac',
        '-b:a', '96k',
        '-metadata', `description=PhotoHubProxy:${normMaster}`,
        '-metadata', `comment=PhotoHubProxy:${normMaster}`,
        '-movflags', '+faststart',
        videoTmp,
      ], 180000);

      let proxyRelativePath = null;
      let proxySize = null;
      if (fs.existsSync(posterTmp)) {
        const posterStat = await fsp.stat(posterTmp);
        if (posterStat.size > 0) {
          await fsp.rename(posterTmp, posterPath);
          proxyRelativePath = `.proxies/${posterName}`;
          proxySize = posterStat.size;
        }
      }

      const videoStat = await fsp.stat(videoTmp);
      if (!videoStat.size) {
        throw makeFallbackError('ffmpeg generated an empty video proxy');
      }
      await fsp.rename(videoTmp, videoPath);
      const proxyHash = await computeFileSha256(videoPath);

      return {
        proxyHash,
        proxyRelativePath,
        proxySize,
        videoProxyRelativePath: `.proxies/${videoName}`,
        videoProxySize: videoStat.size,
      };
    } catch (err) {
      await fsp.unlink(posterTmp).catch(() => {});
      await fsp.unlink(videoTmp).catch(() => {});
      if (err.fallbackToClient) throw err;
      throw makeFallbackError(err.message);
    }
  }

  // Image proxy: try sharp first (fast libvips), then fallback to ffmpeg if sharp cannot decode container
  const imgName = `${normMaster}.jpg`;
  const imgPath = path.join(proxiesDir, imgName);
  const imgTmp = `${imgPath}.tmp.jpg`;

  let imgBuf = null;
  try {
    imgBuf = await generateImageProxyWithSharp(sourcePath, maxPx, qualityPercent);
  } catch (sharpErr) {
    if (await hasFfmpeg()) {
      const targetW = maxPx > 0 ? maxPx : 1440;
      try {
        await runFfmpeg([
          '-y',
          '-i', sourcePath,
          '-frames:v', '1',
          '-vf', `scale='min(${targetW},iw)':-2`,
          '-q:v', '3',
          imgTmp,
        ], 30000);
        imgBuf = await fsp.readFile(imgTmp);
      } catch (ffErr) {
        await fsp.unlink(imgTmp).catch(() => {});
        throw makeFallbackError(ffErr.message || sharpErr.message);
      }
    } else {
      throw makeFallbackError(sharpErr.message);
    }
  }

  if (!imgBuf || imgBuf.length === 0) {
    throw makeFallbackError('Server could not generate compressed image buffer');
  }

  await fsp.writeFile(imgTmp, imgBuf);
  await fsp.rename(imgTmp, imgPath);
  const proxyHash = crypto.createHash('sha256').update(imgBuf).digest('hex');

  return {
    proxyHash,
    proxyRelativePath: `.proxies/${imgName}`,
    proxySize: imgBuf.length,
  };
}

module.exports = {
  isVideoFilename,
  getCapabilities,
  generateServerSideProxy,
};
