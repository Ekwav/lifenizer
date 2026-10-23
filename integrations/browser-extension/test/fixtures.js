// SYNTHETIC fixtures. They mirror the structures documented in public
// scraper write-ups (InnerTube renderers) but were NOT captured from a live
// logged-in session.
const section = (title, contents) => ({
  itemSectionRenderer: { header: { itemSectionHeaderRenderer: { title: { simpleText: title } } }, contents },
});
const videoRenderer = (id, title, channel) => ({
  videoRenderer: { videoId: id, title: { runs: [{ text: title }] }, ownerText: { runs: [{ text: channel }] } },
});
const lockup = (id, title, channel, type = 'LOCKUP_CONTENT_TYPE_VIDEO') => ({
  lockupViewModel: {
    contentId: id, contentType: type,
    metadata: { lockupMetadataViewModel: { title: { content: title },
      metadata: { contentMetadataViewModel: { metadataRows: [{ metadataParts: [{ text: { content: channel } }] }] } } } },
  },
});
const shortsShelf = (id, title) => ({
  reelShelfRenderer: { items: [{ shortsLockupViewModel: {
    overlayMetadata: { primaryText: { content: title } },
    onTap: { innertubeCommand: { reelWatchEndpoint: { videoId: id } } } } }] },
});

const initialData = (lang) => ({
  contents: { twoColumnBrowseResultsRenderer: { tabs: [{ tabRenderer: { content: { sectionListRenderer: { contents: [
    section(lang === 'de' ? 'Heute' : 'Today', [videoRenderer('aaaaaaaaaaa', 'Old shape', 'Chan A'), lockup('bbbbbbbbbbb', 'New shape', 'Chan B')]),
    section(lang === 'de' ? 'Gestern' : 'Yesterday', [lockup('PLAYLIST1', 'a playlist', 'x', 'LOCKUP_CONTENT_TYPE_PLAYLIST'), shortsShelf('ccccccccccc', 'A short')]),
    { continuationItemRenderer: { continuationEndpoint: { continuationCommand: { token: 'T' } } } },
  ] } } } }] } },
});

const continuation = (headerText) => ({
  onResponseReceivedActions: [{ appendContinuationItemsAction: { continuationItems: [
    section(headerText, [videoRenderer('ddddddddddd', 'From continuation', 'Chan D')]),
  ] } }],
});

module.exports = { initialData, continuation, lockup, videoRenderer, section };
