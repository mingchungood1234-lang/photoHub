function formatCheckPayload(lookupResult, reqHash, folderName) {
  const record = lookupResult.record;
  const exists = lookupResult.status !== 'missing';
  const isMaster = lookupResult.status === 'master';
  const isProxy = lookupResult.status === 'proxy';
  const keepOriginalOnDevice = Boolean(record && record.keepOriginalOnDevice);
  return {
    exists,
    isMaster,
    isProxy,
    isProtectedOriginal: keepOriginalOnDevice,
    keepOriginalOnDevice,
    canDelete: isMaster && !keepOriginalOnDevice,
    canReplaceWithProxy: isMaster && !keepOriginalOnDevice,
    masterHash: lookupResult.masterHash,
    ...(folderName !== undefined ? { userFolder: folderName } : {}),
    ...(reqHash !== undefined ? { hash: reqHash } : {}),
    savedPath: record ? record.relativePath : null,
  };
}

function createCheckController() {
  async function checkSingleHash(req, res, rawHash) {
    try {
      const { hashIndex, folderName } = req.userContext;
      const normalized = String(rawHash || '').trim().toLowerCase();
      const lookupResult = await hashIndex.lookup(normalized);
      return res.json({
        success: true,
        ...formatCheckPayload(lookupResult, normalized, folderName),
      });
    } catch (err) {
      return res.status(500).json({
        success: false,
        exists: false,
        canDelete: false,
        canReplaceWithProxy: false,
        error: err.message,
      });
    }
  }

  return {
    checkByParam(req, res) {
      return checkSingleHash(req, res, req.params.hash);
    },

    checkByBody(req, res) {
      const hash = req.body && (req.body.hash || req.body.sha256);
      if (!hash || typeof hash !== 'string') {
        return res.status(400).json({
          success: false,
          exists: false,
          canDelete: false,
          canReplaceWithProxy: false,
          error: 'Missing "hash" field in JSON body',
        });
      }
      return checkSingleHash(req, res, hash);
    },

    async checkBatch(req, res) {
      try {
        const hashes = req.body && req.body.hashes;
        if (!Array.isArray(hashes)) {
          return res.status(400).json({
            success: false,
            error: 'Missing "hashes" array in JSON body',
          });
        }
        if (hashes.length > 500) {
          return res.status(400).json({
            success: false,
            error: 'Maximum 500 hashes per batch request',
          });
        }

        const { hashIndex } = req.userContext;
        const results = {};
        for (const rawHash of hashes) {
          if (typeof rawHash !== 'string' || !rawHash.trim()) continue;
          const normalized = rawHash.trim().toLowerCase();
          const lookupResult = await hashIndex.lookup(normalized);
          results[normalized] = formatCheckPayload(lookupResult, undefined, undefined);
        }

        return res.json({
          success: true,
          results,
        });
      } catch (err) {
        return res.status(500).json({
          success: false,
          error: err.message,
        });
      }
    },
  };
}

module.exports = { createCheckController, formatCheckPayload };
