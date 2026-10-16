/** MOBI service entry point: conversion, inspection, metadata editing, batches
 * and the vendor/format inventories. */
export { convertMobi, inspectMobi } from './convert';
export { convertDirectory, collectBooks } from './batch';
export { readMetadata, rewriteMetadata, embedCover, EXTH_TAGS } from './metadata';
export { inspectCover, coverKind, COVER_NAMES } from './cover';
export { describeSource, isBinarySource } from './source';
export { vendorStatus, vendorSummary, engineStatus, ENGINES } from './vendors';
export { textSourceFormats, TEXT_SOURCES, convertTextSource } from './source/index';
export { sourceKind, TEXT_EXTENSIONS } from './formats';
export type { BatchEntry, BatchOptions, BatchReport } from './batch';
export type { MobiMetadata, MetadataField, MetadataChanges } from './metadata';
export type { CoverImage } from './cover';
export type { TextSource, TextSourceId } from './source/index';
export type { VendorEngine, VendorStatus } from './vendors';
export { mobiBinary, pythonBinary, decodeBook, independentDecode, nativeInspect } from './runtime';
export { createMobiBytes } from './writer';
export { conversionFormats, sourceFormat } from './formats';
export { markupChapters } from './html-text';
export { epubText } from './epub-text';
export { settings } from './options';
export type { Backend, Settings } from './options';
export type { MobiInfo, ConversionOptions, ConversionResult } from './types';
export type { EbookFormat } from './formats';
