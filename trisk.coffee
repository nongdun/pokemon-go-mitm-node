###
  Pokemon Go(c) MITM node proxy
  by Michael Strassburger <codepoet@cpan.org>
  This example intercetps the server answer after a successful throw and signals
  the App that the pokemon has fleed - cleaning up can be done at home :)

  Be aware: This triggers an error message in the App but won't interfere further on

  Pokemon Go (c) ManInTheMiddle Radar "mod"
  Michael Strassburger <codepoet@cpan.org>

  Enriches every PokeStop description with information about
  - directions to nearby wild pokemons
  - time left if a PokeStop has an active lure

###

PokemonGoMITM = require './lib/pokemon-go-mitm'
changeCase = require 'change-case'
moment = require 'moment'
LatLon = require('geodesy').LatLonSpherical

pokemons = []
currentLocation = null

server = new PokemonGoMITM port: 8081
	# Replace successful catch with escape to save time
	.addResponseHandler "CatchPokemon", (data) ->
		console.log "tried to catch pokemon", data
		#data.status = 'CATCH_FLEE' if data.status is 'CATCH_SUCCESS'
		data.status = 'CATCH_ESCAPE' if data.status is 'CATCH_SUCCESS'
		data
	# Append the IV percentage to the end of names in our inventory
	.addResponseHandler "GetInventory", (data) ->
		if data.inventory_delta
			for item in data.inventory_delta.inventory_items
				if pokemon = item.inventory_item_data.pokemon_data
					iv = 100 * (pokemon.individual_attack + pokemon.individual_defense + pokemon.individual_stamina) / 45
					pokemon.nickname = "#{pokemon.nickname} #{iv}%"
		data
	# Fetch our current location as soon as it gets passed to the API
	.addRequestHandler "GetMapObjects", (data) ->
		currentLocation = new LatLon data.latitude, data.longitude
		console.log "[+] Current position of the player #{currentLocation}"
		false

	# Parse the wild pokemons nearby
	.addResponseHandler "GetMapObjects", (data) ->
		pokemons = []
		seen = {}
		addPokemon = (pokemon) ->
			return if seen[hash = pokemon.spawnpoint_id + ":" + pokemon.pokemon_data.pokemon_id]
			return if pokemon.time_till_hidden_ms < 0

			seen[hash] = true
			pokemons.push
				type: pokemon.pokemon_data.pokemon_id
				latitude: pokemon.latitude
				longitude: pokemon.longitude
				expirationMs: Date.now() + pokemon.time_till_hidden_ms
				data: pokemon.pokemon_data

		for cell in data.map_cells
			addPokemon pokemon for pokemon in cell.wild_pokemons

		false

	# Whenever a poke spot is opened, populate it with the radar info!
	.addResponseHandler "FortDetails", (data) ->
		console.log "fetched fort request", data
		info = ""

		for modifier in data.modifiers
			if modifier.item_id is 'ITEM_TROY_DISK'
				expires = moment(Number(modifier.expiration_timestamp_ms)).toNow()
				info += "Lure expires in #{expires}\n"
				info += "Lure set by #{modifier.deployer_player_codename}\n"
				#info += "Lure expires in "+moment(data.modifiers[0].expirationMs).toNow()+"\n"

		info += if pokemons.length
			(pokemonInfo(pokemon) for pokemon in pokemons).join "\n"
		else
			"No wild Pokémon nearby..."

		data.description = info
		data

# Populate some neat info about the pokemon's whereabouts 
pokemonInfo = (pokemon) ->
	console.log pokemon
	name = changeCase.titleCase pokemon.data.pokemon_id
	cp = pokemon.data.cp
	position = new LatLon pokemon.latitude, pokemon.longitude
	expires = moment(Number(pokemon.expirationMs)).toNow
	distance = Math.floor currentLocation.distanceTo position
	bearing = currentLocation.bearingTo position
	direction = switch true
		when bearing>330 then "N"
		when bearing>285 then "NW"
		when bearing>240 then "W"
		when bearing>195 then "SW"
		when bearing>150 then "S"
		when bearing>105 then "SE"
		when bearing>60 then "E"
		when bearing>15 then "NE"
		else "N"

	"#{name} #{cp} CP in #{distance}m -> #{direction} expires in #{expires}"
