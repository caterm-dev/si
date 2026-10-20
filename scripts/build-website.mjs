#!/usr/bin/env node
// Zero-dependency generation of crawlable, localized static pages.
import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = path.join(root, 'website');
const output = path.join(root, '.build/website');
const locales = [
    { file: 'en.json', route: '', base: './', enCurrent: 'aria-current="page"', zhCurrent: '' },
    { file: 'zh-CN.json', route: 'zh', base: '../', enCurrent: '', zhCurrent: 'aria-current="page"' },
];
const template = await readFile(path.join(source, 'template.html'), 'utf8');
const escapeHTML = value => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
const release = JSON.parse(await readFile(path.join(source, 'release.json'), 'utf8'));
const architectures = { arm64: 'Apple Silicon', x86_64: 'Intel', universal: 'Apple Silicon + Intel' };
if (!/^\d+\.\d+\.\d+$/.test(release.version) || !Object.hasOwn(architectures, release.architecture)) {
    throw new Error('Invalid website release version or architecture');
}
const imageName = `SI-${release.version}-${release.architecture}.dmg`;
const releaseAssets = {};
for (const [key, name] of Object.entries({ download: imageName, checksum: `${imageName}.sha256`, source: `SI-${release.version}-source.tar.gz` })) {
    const asset = release.assets?.[name];
    const url = new URL(asset?.url);
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash
        || !url.pathname.endsWith(`/releases/${release.version}/mac/${release.architecture}/${name}`)
        || !Number.isSafeInteger(asset.size) || asset.size <= 0 || !/^[a-f0-9]{64}$/.test(asset.sha256)) {
        throw new Error(`Invalid website release asset: ${name}`);
    }
    releaseAssets[key] = asset;
}
const dictionaries = await Promise.all(locales.map(async locale => JSON.parse(await readFile(path.join(source, 'locales', locale.file), 'utf8'))));
const keys = Object.keys(dictionaries[0]).sort().join(',');
for (const [index, dictionary] of dictionaries.entries()) {
    if (Object.keys(dictionary).sort().join(',') !== keys) throw new Error(`Translation keys differ: ${locales[index].file}`);
    for (const [key, value] of Object.entries(dictionary)) {
        if (typeof value !== 'string' || !value.trim()) throw new Error(`Missing translation: ${locales[index].file}:${key}`);
    }
}
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(path.join(source, 'assets'), path.join(output, 'assets'), { recursive: true });
for (const [index, locale] of locales.entries()) {
    const dictionary = dictionaries[index];
    const raw = { base: locale.base, home: './', enCurrent: locale.enCurrent, zhCurrent: locale.zhCurrent };
    const size = new Intl.NumberFormat(dictionary.lang, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(releaseAssets.download.size / 1_000_000);
    const values = {
        ...dictionary,
        downloadUrl: releaseAssets.download.url,
        checksumUrl: releaseAssets.checksum.url,
        sourceUrl: releaseAssets.source.url,
        releaseDetails: `v${release.version} · ${architectures[release.architecture]} · ${size} MB · DMG`,
    };
    const html = template.replace(/\{\{(\w+)\}\}/g, (_, key) => {
        if (Object.hasOwn(raw, key)) return raw[key];
        if (!Object.hasOwn(values, key)) throw new Error(`Unknown template key: ${key}`);
        return escapeHTML(values[key]);
    });
    const destination = path.join(output, locale.route);
    await mkdir(destination, { recursive: true });
    await writeFile(path.join(destination, 'index.html'), html);
}
await writeFile(path.join(output, '.nojekyll'), '');
console.log(`Built English and Simplified Chinese pages in ${output}`);
