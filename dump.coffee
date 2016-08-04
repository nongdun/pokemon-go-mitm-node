###
  Pokemon Go(c) MITM node proxy
  by Michael Strassburger <codepoet@cpan.org>

  This example just dumps all in-/outgoing messages and responses

###

PokemonGoMITM = require './lib/mitm-dump'

# Uncomment if you want to filter the regular messages
# ignore = ['GetHatchedEggs', 'DownloadSettings', 'GetInventory', 'CheckAwardedBadges', 'GetMapObjects']
ignore = []

server = new PokemonGoMITM port: 8081, debug: true
