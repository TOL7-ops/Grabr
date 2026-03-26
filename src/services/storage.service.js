const path = require("path");
const fs = require("fs");
const config = require("../config");

/**
 * Returns a public download URL and verifies the file exists within
 * the allowed download directory (prevents path traversal).
 */
function resolveDownloadUrl(filename) {
  const downloadDir = path.resolve(config.storage.downloadPath);
  const filePath = path.resolve(path.join(downloadDir, filename));

  // Ensure resolved path is within the download directory
  if (!filePath.startsWith(downloadDir + path.sep)) {
    throw Object.assign(new Error("Invalid filename"), { status: 400 });
  }

  if (!fs.existsSync(filePath)) {
    throw Object.assign(new Error("File not found"), { status: 404 });
  }

  return {
    filePath,
    downloadUrl: `${config.baseUrl}/files/${encodeURIComponent(filename)}`,
  };
}

/**
 * Returns file metadata (size, modified date) for a given filename.
 */
function getFileInfo(filename) {
  const { filePath } = resolveDownloadUrl(filename);
  const stat = fs.statSync(filePath);
  return {
    filename,
    sizeBytes: stat.size,
    createdAt: stat.birthtime,
    modifiedAt: stat.mtime,
  };
}

module.exports = { resolveDownloadUrl, getFileInfo };