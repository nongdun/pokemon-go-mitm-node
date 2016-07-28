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
spawnPoints = []
forts = []
currentLocation = null

# Get encounter details
handleEncounter = (data, action) ->
	console.log "#{action} with pokemon", data
	if data.capture_probability
		# Reporting high probability to app makes it harder to miss
		data.capture_probability.capture_probability = new Float32Array [1, 1, 1]
	data

server = new PokemonGoMITM port: 8081
	# Append the IV% to the end of names in our inventory
	.addResponseHandler "GetInventory", (data) ->
		if data.inventory_delta
			for item in data.inventory_delta.inventory_items when item.inventory_item_data
				if pokemon = item.inventory_item_data.pokemon_data
					name = pokemon.nickname or changeCase.titleCase pokemon.pokemon_id
					atk = pokemon.individual_attack or 0
					def = pokemon.individual_defense or 0
					sta = pokemon.individual_stamina or 0
					iv = Math.round((atk + def + sta) * 100/45)
					pokemon.nickname = "#{name} #{iv}%"

		data
	# Fetch our current location as soon as it gets passed to the API
	.addRequestHandler "GetMapObjects", (data) ->
		currentLocation = new LatLon data.latitude, data.longitude
		timestampMs = Date.now()
		console.log "[+] Current position of the player #{currentLocation}"

		for fort in forts when fort.type is 'CHECKPOINT'
			#if not fort.cooldown_complete_timestamp_ms or Date.now() >= parseInt(fort.cooldown_complete_timestamp_ms) - 7200000 + 300000
			if not fort.cooldown_complete_timestamp_ms or timestampMs >= parseInt(fort.cooldown_complete_timestamp_ms)
				position = new LatLon fort.latitude, fort.longitude
				distance = Math.floor currentLocation.distanceTo position
				fort.cooldown_complete_timestamp_ms = (Date.now() + 300000).toString();
				if distance < 30
					server.craftRequest "FortSearch", {
							fort_id: fort.id,
							fort_latitude: fort.latitude,
							fort_longitude: fort.longitude,
							player_latitude: currentLocation.lat,
							player_longitude: currentLocation.lon,
						}
					.then (data) ->
						if data.result is 'SUCCESS'
							console.log "[<-] Items awarded:", data.items_awarded
		false

	.addResponseHandler "GetMapObjects", (data) ->
		forts = []
		for cell in data.map_cells
			for fort in cell.forts
				forts.push fort
		false
	.addResponseHandler "GetMapObjects", (data) ->
		spawnPoints = []
		for cell in data.map_cells
			for sp in cell.spawn_points
			    spawnPoints.push sp
		false
	# Parse the wild pokemons nearby
	.addResponseHandler "GetMapObjects", (data) ->
		timestampMs = Date.now()
		tooFar = 200

		oldPokemons = pokemons
		pokemons = []
		seen = {}
		addPokemon = (pokemon) ->
			return if seen[pokemon.encounter_id]
			return if pokemon.time_till_hidden_ms < 0

			expirationMs = timestampMs + pokemon.time_till_hidden_ms
			seen[pokemon.encounter_id] = expirationMs

			console.log "new wild pokemon", pokemon
			pokemons.push
				encounterId: pokemon.encounter_id
				latitude: pokemon.latitude
				longitude: pokemon.longitude
				expirationMs: expirationMs
				data: pokemon.pokemon_data

		for cell in data.map_cells
			addPokemon pokemon for pokemon in cell.wild_pokemons

		if not currentLocation
			return false

		# Clean up expired pokemon
		for pokemon in oldPokemons when pokemon.expirationMs > timestampMs
			continue if seen[pokemon.encounterId]
			position = new LatLon pokemon.latitude, pokemon.longitude
			if tooFar > currentLocation.distanceTo position
				pokemons.push pokemon

		# Sort by nearest (rounded to 10m)
		pokemons.sort (p1, p2) ->
			d1 = currentLocation.distanceTo new LatLon(p1.latitude, p1.longitude)
			d2 = currentLocation.distanceTo new LatLon(p2.latitude, p2.longitude)
			Math.floor((d1 - d2) / 10)

		false

	# Whenever a poke spot is opened, populate it with the radar info!
	.addResponseHandler "FortDetails", (data) ->
		console.log "fetched fort request", data
		info = ""
		mapTooFar = 150

		# Populate some neat info about the pokemon's whereabouts
		pokemonInfo = (pokemon) ->
			name = changeCase.titleCase pokemon.data.pokemon_id

			position = new LatLon pokemon.latitude, pokemon.longitude
			expires = moment(Number(pokemon.expirationMs)).fromNow()
			distance = Math.floor currentLocation.distanceTo position
			bearing = currentLocation.bearingTo position
			direction = switch true
				when bearing>330 then "↑"
				when bearing>285 then "↖"
				when bearing>240 then "←"
				when bearing>195 then "↙"
				when bearing>150 then "↓"
				when bearing>105 then "↘"
				when bearing>60 then "→"
				when bearing>15 then "↗"
				else "↑"

			"#{name} #{direction} #{distance}m expires #{expires}"

		# Create map marker for pokemon location
		pokemonMarker = (pokemon) ->
			label = pokemon.data.pokemon_id.charAt(0)
			icon = changeCase.paramCase pokemon.data.pokemon_id
			position = new LatLon pokemon.latitude, pokemon.longitude
			if mapTooFar < currentLocation.distanceTo position
				return ""
			marker = "label:#{label}%7Cicon:http://raw.github.com/msikma/pokesprite/master/icons/pokemon/regular/#{icon}.png"

			"&markers=#{marker}%7C#{pokemon.latitude},#{pokemon.longitude}"

		for modifier in data.modifiers
			if modifier.item_id is 'ITEM_TROY_DISK'
				expires = moment(Number(modifier.expiration_timestamp_ms)).fromNow()
				info += "Lure by #{modifier.deployer_player_codename} expires #{expires}\n"

		if currentLocation
			loc = "#{currentLocation.lat},#{currentLocation.lon}"
			img = "http://maps.googleapis.com/maps/api/staticmap?center=#{loc}&zoom=17&size=384x512&markers=color:blue%7Csize:tiny%7C#{loc}"

			spMarkers = ""
			for sp in spawnPoints
				position = new LatLon sp.latitude, sp.longitude
				if mapTooFar > currentLocation.distanceTo position
					spMarkers += "%7C#{sp.latitude},#{sp.longitude}"

			if spMarkers.length 
				img += "&markers=color:green%7Csize:tiny#{spMarkers}"

			if pokemons.length
				img += (pokemonMarker(pokemon) for pokemon in pokemons).join ""

			data.image_urls.unshift img

		info += if pokemons.length and currentLocation
			(pokemonInfo(pokemon) for pokemon in pokemons).join "\n"
		else
			"No wild Pokémon near you..."

		data.description = info
		data

	.addResponseHandler "Encounter", handleEncounter
	.addResponseHandler "DiskEncounter", handleEncounter
	.addResponseHandler "IncenseEncounter", handleEncounter

	.addRequestHandler "CatchPokemon", (data) ->
		console.log "trying to catch pokemon", data
		if data.spin_modifier < 0.85
			data.spin_modifier = 0.80 + data.spin_modifier % 0.10
		if data.normalized_reticle_size < 1.95
			data.normalized_reticle_size = 1.90 + data.normalized_reticle_size % 0.10
		if data.hit_pokemon
			data.normalized_hit_position = 1.0
		data

	# Replace successful catch with escape to save time
	.addResponseHandler "CatchPokemon", (data) ->
		console.log "tried to catch pokemon", data
		data.status = 'CATCH_FLEE' if data.status is 'CATCH_SUCCESS'
		data
