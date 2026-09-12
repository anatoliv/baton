# OpenSubsonic compatibility

Baton is built on the Subsonic 1.16.1 API and uses OpenSubsonic features when the server
provides them. It does not treat a successful connection as proof that every OpenSubsonic
extension is available. The server advertises its extensions through
`getOpenSubsonicExtensions`, and Baton keeps working against classic Subsonic servers that do
not implement that endpoint.

## OpenSubsonic extensions

- `apiKeyAuthentication` version 1 is supported. In API key mode, Baton sends `apiKey` and
  omits the username, token, and salt parameters. The connection check recognizes the current
  extension name and the older `apikeyauth` name used by some servers.
- `songLyrics` version 1 has basic support. Baton calls `getLyricsBySongId` and reads the first
  returned lyrics set, including synchronized line start times. It does not yet use the
  optional artist, title, language, or offset metadata, and it does not implement version 2
  agents, cues, or lyric kinds.

Baton calls `getOpenSubsonicExtensions` at connection time to decide what a server supports.
The response carries a name and a version list per extension; the client's public connection
result currently exposes the names.

## Extended response metadata

Baton reads the following OpenSubsonic fields when a server includes them:

- Songs: bit depth, sample rate, channel count, last-played date, BPM, comment, MusicBrainz ID,
  multiple genres, display artist, and ReplayGain track and album gain and peak values.
- Albums: last-played date, user rating, MusicBrainz ID, multiple genres, display artist,
  release types, original release date, and compilation status.
- Artists: MusicBrainz ID and roles.

Unknown response fields are ignored, so servers may add newer metadata without breaking the
client.

## Extensions not yet implemented

Baton does not currently implement `formPost`, `transcodeOffset`, `getPodcastEpisode`,
`indexBasedQueue`, `playbackReport`, `sonicSimilarity`, `topSongsByArtistId`, `transcoding`, or
`songLyrics` version 2. Similar-song search, playback scrobbling, transcoded streaming, podcast
browsing, and play-queue persistence are available through the corresponding Subsonic 1.16.1
endpoints, but that does not imply support for the newer OpenSubsonic extensions with similar
names.

## References

- [OpenSubsonic API key authentication](https://opensubsonic.netlify.app/docs/extensions/apikeyauth/)
- [OpenSubsonic song lyrics](https://opensubsonic.netlify.app/docs/extensions/songlyrics/)
- [OpenSubsonic extension discovery](https://opensubsonic.netlify.app/docs/endpoints/getopensubsonicextensions/)
- [Baton source](https://github.com/anatoliv/baton)
