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
forts = []
currentLocation = null
mapRadius = 150 # Approx size of level 15 s2 cell

# Get encounter details
handleEncounter = (data, action) ->
	console.log "#{action} with pokemon", data
	if data.capture_probability
		# Reporting high probability to app makes it harder to miss
		data.capture_probability.capture_probability = new Float32Array [1, 1, 1]
	data

server = new PokemonGoMITM port: 8081, debug: true
	#.addResponseHandler "DownloadSettings", (data) ->
	#	if data.settings
	#		data.settings.map_settings.pokemon_visible_range = 1500
	#		data.settings.map_settings.poke_nav_range_meters = 1500
	#		data.settings.map_settings.encounter_range_meters = 100
	#		data.settings.fort_settings.interaction_range_meters = 50
	#		data.settings.fort_settings.max_total_deployed_pokemon = 50
	#	data
	# Always get the full inventory
	.addRequestHandler "*", (data, action) ->
		console.log "[<-] Request #{action}:", data
	.addResponseHandler "*", (data, action) ->
		console.log "[<-] Response #{action}:", data

	.addRequestHandler "GetInventory", (data) ->
		return false
		data.last_timestamp_ms = 0
		data

	# Append IV% to existing Pokémon names
	.addResponseHandler "GetInventory", (data) ->
		if data.inventory_delta
			for item in data.inventory_delta.inventory_items when item.inventory_item_data
				if pokemon = item.inventory_item_data.pokemon_data
					id = changeCase.titleCase pokemon.pokemon_id
					name = pokemon.nickname or id.replace(" Male", "♂").replace(" Female", "♀")
					atk = pokemon.individual_attack or 0
					def = pokemon.individual_defense or 0
					sta = pokemon.individual_stamina or 0
					iv = Math.round((atk + def + sta) * 100/45)
					pokemon.nickname = "#{name} #{iv}%"

		data

	# Fetch our current location as soon as it gets passed to the API
	.addRequestHandler "GetMapObjects", (data) ->
		currentLocation = new LatLon data.latitude, data.longitude
		console.log "[+] Current position of the player #{currentLocation}"
		false

	.addResponseHandler "GetMapObjects", (data) ->
		return false if not data.map_cells.length
		forts = []
		for cell in data.map_cells
			for fort in cell.forts
				forts.push fort

		return false
		# Use server timestamp
		timestampMs = Number(data.map_cells[0].current_timestamp_ms)
		for fort in forts when fort.type is 'CHECKPOINT'
			#if not fort.cooldown_complete_timestamp_ms or Date.now() >= Number(fort.cooldown_complete_timestamp_ms) - 7200000 + 300000
			if not fort.cooldown_complete_timestamp_ms or timestampMs >= fort.cooldown_complete_timestamp_ms
				position = new LatLon fort.latitude, fort.longitude
				distance = Math.floor currentLocation.distanceTo position
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
								fort.cooldown_complete_timestamp_ms = (timestampMs + 300000).toString();
								console.log "[<-] Items awarded:", data.items_awarded
		false
	# Parse the wild pokemons nearby
	.addResponseHandler "GetMapObjects", (data) ->
		return false if not data.map_cells.length

		oldPokemons = pokemons
		pokemons = []
		seen = {}

		# Store wild pokemons
		addPokemon = (pokemon) ->
			return if seen[pokemon.encounter_id]
			return if pokemon.time_till_hidden_ms < 0

			console.log "new wild pokemon", pokemon
			pokemons.push pokemon
			seen[pokemon.encounter_id] = pokemon
		for cell in data.map_cells
			addPokemon pokemon for pokemon in cell.wild_pokemons

		# Use server timestamp
		timestampMs = Number(data.map_cells[0].current_timestamp_ms)
		# Add previously known pokemon, unless expired
		for pokemon in oldPokemons when not seen[pokemon.encounter_id]
			expirationMs = Number(pokemon.last_modified_timestamp_ms) + pokemon.time_till_hidden_ms
			pokemons.push pokemon unless expirationMs < timestampMs
			seen[pokemon.encounter_id] = pokemon
		# Correct nearby steps display for known nearby Pokémon (idea by @zaksabeast)
		return false if not currentLocation
		for cell in data.map_cells
			for nearby in cell.nearby_pokemons when seen[nearby.encounter_id]
				pokemon = seen[nearby.encounter_id]
				position = new LatLon pokemon.latitude, pokemon.longitude
				nearby.distance_in_meters = Math.floor currentLocation.distanceTo position
		data
	# Whenever a poke spot is opened, populate it with the radar info!
	.addResponseHandler "FortDetails", (data) ->
		console.log "fetched fort request", data
		info = ""

		# Limit to map radius
		mapPokemons = []
		for pokemon in pokemons
			position = new LatLon pokemon.latitude, pokemon.longitude
			if mapRadius > currentLocation.distanceTo position
				mapPokemons.push pokemon
		# Sort pokemons by distance
		mapPokemons.sort (p1, p2) ->
			d1 = currentLocation.distanceTo new LatLon(p1.latitude, p1.longitude)
			d2 = currentLocation.distanceTo new LatLon(p2.latitude, p2.longitude)
			d1 - d2

		# Populate some neat info about the pokemon's whereabouts
		pokemonInfo = (pokemon) ->
			name = changeCase.titleCase pokemon.pokemon_data.pokemon_id
			name = name.replace(" Male", "♂").replace(" Female", "♀")
			expirationMs = Number(pokemon.last_modified_timestamp_ms) + pokemon.time_till_hidden_ms
			position = new LatLon pokemon.latitude, pokemon.longitude
			expires = moment(expirationMs).fromNow()
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
			addMarker(pokemon.pokemon_data.pokemon_id, pokemon.latitude, pokemon.longitude)

			"#{name} #{direction} #{distance}m expires #{expires}"

		# Create map marker for pokemon location
		markers = {}
		addMarker = (id, lat, lon) ->
			label = id.charAt(0)
			name = changeCase.paramCase id.replace(/_([MF]).*/, "_$1")
			icon = "http://raw.github.com/msikma/pokesprite/master/icons/pokemon/regular/#{name}.png"
			markers[id] = "&markers=label:#{label}%7Cicon:#{icon}" if not markers[id]
			markers[id] += "%7C#{lat},#{lon}"

		for modifier in data.modifiers when modifier.item_id is 'ITEM_TROY_DISK'
			expires = moment(Number(modifier.expiration_timestamp_ms)).fromNow()
			info += "Lure by #{modifier.deployer_player_codename} expires #{expires}\n"

		info += if mapPokemons.length and currentLocation
			(pokemonInfo(pokemon) for pokemon in mapPokemons).join "\n"
		else
			"No wild Pokémon near you..."

		if currentLocation
			loc = "#{currentLocation.lat},#{currentLocation.lon}"
			img = "http://maps.googleapis.com/maps/api/staticmap?" +
				"center=#{loc}&zoom=17&size=384x512&markers=color:blue%7Csize:tiny%7C#{loc}"
			img += (marker for id, marker of markers).join ""
			data.image_urls.unshift img

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
	# show incense response
	.addResponseHandler "GetIncensePokemon", (data) ->
		console.log "incense pokemon", data
		false
