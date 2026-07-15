const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const root = path.resolve(__dirname, '..');
const sourcePath = path.join(root, 'outputs', 'logo', 'ruoya-ai-app-icon.svg');
const assetRoot = path.join(root, 'iina', 'Assets.xcassets');
const iconSets = [
  'AppIcon.appiconset',
  'AppIconDebug.appiconset',
  'AppIconBeta.appiconset',
  'AppIconNightly.appiconset',
];

function pixelSize(image) {
  const points = Number.parseFloat(image.size.split('x')[0]);
  const scale = Number.parseInt(image.scale, 10);
  return Math.round(points * scale);
}

async function main() {
  if (!fs.existsSync(sourcePath)) {
    throw new Error(`Missing canonical logo: ${sourcePath}`);
  }

  const source = fs.readFileSync(sourcePath);
  const written = [];

  for (const iconSet of iconSets) {
    const iconSetDir = path.join(assetRoot, iconSet);
    const contents = JSON.parse(fs.readFileSync(path.join(iconSetDir, 'Contents.json'), 'utf8'));

    for (const image of contents.images) {
      if (!image.filename) continue;
      const size = pixelSize(image);
      const output = path.join(iconSetDir, image.filename);
      await sharp(source, { density: 240 })
        .resize(size, size)
        .png({ compressionLevel: 9 })
        .toFile(output);
      written.push({ iconSet, filename: image.filename, size });
    }
  }

  console.log(JSON.stringify({ source: sourcePath, filesWritten: written.length, iconSets, written }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
