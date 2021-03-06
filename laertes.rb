#!/usr/bin/env ruby

# This file is part of Laertes.
#
# Laertes is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Laertes is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Laertes.  If not, see <http://www.gnu.org/licenses/>.
#
# Copyright 2013 William Denton

# CONFIGURING
#
# Configuration details are set in the file config.json.
# Make a copy of config.json.example and edit it.
#
# Twitter configuration is done in environment variables.

require 'json'
require 'time'
require 'date'
require 'cgi'

require 'rubygems'
require 'bundler/setup'
require 'twitter'

require 'sinatra'
require 'nokogiri'
require 'open-uri'

before do
  # Make this the default
  content_type 'application/json'
end

configure do
  begin
    set(:config) { JSON.parse(File.read("config.json")) }
  rescue Exception => e
    puts e
    exit
  end

end

# UIC Fourm: 41.866862,-87.64597

# URL being called looks like this:
#
# /?
# lang=en
# & countryCode=CA
# & userId=6f85012345
# & lon=-79.000000
# & version=6.0
# & radius=1500
# & lat=43.00000
# & layerName=code4lib2013
# & accuracy=100

# Mandatory params passed in:
# userId
# layerName
# version
# lat
# lon
# countryCode
# lang
# action
#
# Optional but important
# radius

get "/" do

  # Status 0 indicates success. Change to number in range 20-29 if there's a problem.
  errorcode = 0
  errorstring = "ok"

  layer = settings.config.find {|l| l["layer"] == params[:layerName] }

  show_tweets = true
  show_map_points = true
  tweet_time_limit = nil

  if layer

    radius = 1500 # Default to 1500m radius if none provided

    if params[:radius] # But override it if another radius is passed in
      radius = params[:radius].to_f
    end

    hotspots = []

    icon_url = layer["icon_url"] || "https://maps.gstatic.com/mapfiles/ms2/micons/blue-dot.png"

    # Along with the mandatory search radius option, two others can be set up.
    #
    # First, a checkbox to set which or both of tweets and map points should be shown.
    # Use these values:
    # CHECKBOXLIST = 1 : Show tweets
    # CHECKBOXLIST = 2 : Show map points
    #
    if params[:CHECKBOXLIST]
      checkboxes = params[:CHECKBOXLIST].split(",")
      logger.debug "Checkboxes = #{checkboxes}"
      if ! checkboxes.include? "1"
        show_tweets = false
        logger.info "Not showing tweets"
      end
      if ! checkboxes.include? "2"
        show_map_points = false
        logger.info "Not showing map points"
      end
    end

    if ! show_tweets and ! show_map_points
      logger.debug "This will not be informative"
    end

    # CHECKBOXLIST=1&version=7.1&radius=2000&lat=43.6840131&layerName=laertesdev&action=refresh&acc
    # CHECKBOXLIST=1%2C2

    # Second, radio buttons to limit tweets to certain time ranges:
    # RADIOLIST = 1: Last hour
    # RADIOLIST = 4: Last 4 hours
    # RADIOLIST = 8: Last 24 hours
    # RADIOLIST = 16: Today
    # RADIOLIST = 32: All
    t = Time.now
    case params[:RADIOLIST].to_i
    when 1
      tweet_time_limit = t - 60*60 # One hour
    when 4
      tweet_time_limit = t - 4*60*60 # Four hours
    when 8
      tweet_time_limit = t - 24*60*60 # 24 hours
    when 16
      tweet_time_limit = t.to_date.to_time # Strips time to 00:00:00, ie "today"
    when 32
      # Leave it at nil
    end

    if tweet_time_limit
      logger.info "Tweet time limit set to '#{tweet_time_limit}' with parameter #{params[:RADIOLIST].to_i}"
    end

    # http://stackoverflow.com/questions/279769/convert-to-from-datetime-and-time-in-ruby
    # http://stackoverflow.com/questions/238684/subtract-n-hours-from-a-datetime-in-ruby

    counter = 1;

    #
    # First source: grab points of interest from Google Maps.
    #

    if show_map_points
      layer["google_maps"].each do |map_url|
        begin
          kml = Nokogiri::XML(open(map_url + "&output=kml"))
          kml.xpath("//xmlns:Placemark").each do |p|
            if p.css("Point").size > 0 # Nicer way to ignore everything that doesn't have a Point element?

              # Some of the points will be out of range, but lets assume there won't be too many,
              # and we'll deal with it below

              # Ignore all points that are too far away
              longitude, latitude, altitude = p.css("coordinates").text.split(",")
              next if distance_between(params[:lat], params[:lon], latitude, longitude) > radius

              # But if it's within range, build the hotspot information for Layar
              hotspot = {
                "id" => counter, # Could keep a counter but this is good enough
                "text" => {
                  "title" => p.css("name").text,
                  "description" => Nokogiri::HTML(p.css("description").text).css("div").text,
                  # For the description, which is in HTML, we need to pick out the text of the
                  # element from the XML and then parse it as HTML.  I think.  Seems kooky.
                  "footnote" => ""
                },
                "anchor" => {
                  "geolocation" => {
                    "lat" => latitude.to_f,
                    "lon" => longitude.to_f
                  }
                },
                "imageURL" => icon_url,
                "icon" => {
                  "url" => icon_url,
                  "type" =>  0
                },
              }
              hotspots << hotspot
              counter += 1
            end
          end
        rescue Exception => error
          # TODO Catch errors better
          logger.error "Error: #{error}"
        end
      end
    end

    logger.debug "Map points returned: #{hotspots.length}"

    #
    # Second source: look for any tweets that were made nearby and also use the right hash tags.
    #
    # Details about the Twitter Search API (simpler than the full API):
    # Twitter Search API: https://dev.twitter.com/docs/using-search
    #
    # Responses: https://dev.twitter.com/docs/platform-objects/tweets
    #
    # Geolocating of tweets in the response:
    # https://dev.twitter.com/docs/platform-objects/tweets#obj-coordinates

    if show_tweets
      radius_km = radius / 1000 # Twitter wants the radius in km

      # begin
      #   twitter_config = JSON.parse(File.read("twitter.json"))
      # rescue Exception => e
      #   STDERR.puts "No readable twitter.json settings file: #{e}"
      #   exit
      # end

      if ENV['LAERTES_CONSUMER_KEY'].nil? || ENV['LAERTES_CONSUMER_SECRET'].nil? || ENV['LAERTES_ACCESS_TOKEN'].nil? || ENV['LAERTES_ACCESS_TOKEN_SECRET'].nil?
        logger.debug "Twitter environment variables are not set; Twitter search will not work. See documentation for how to set this up"
      end

      client = Twitter::REST::Client.new do |config|
        config.consumer_key        = ENV['LAERTES_CONSUMER_KEY']
        config.consumer_secret     = ENV['LAERTES_CONSUMER_SECRET']
        config.access_token        = ENV['LAERTES_ACCESS_TOKEN']
        config.access_token_secret = ENV['LAERTES_ACCESS_TOKEN_SECRET']
      end

      begin
        # client.search("#{layer[:search]}", :result_type => "recent").take(100).each do |tweet|
        twitter_query = "#{CGI.escape(layer['search'])} geocode:#{params[:lat]},#{params[:lon]},#{radius_km}km"
        logger.debug "Searching Twitter for '#{twitter_query}'"
        client.search(twitter_query, :result_type => "recent").take(100).each do |tweet|

          logger.debug "Found tweet #{tweet.id}: '#{tweet.text}'"

          if tweet_time_limit and tweet.created_at < tweet_time_limit
            logger.debug "Skipping tweet #{tweet.id}: #{Time.parse(tweet.created_at)} < #{tweet_time_limit}"
            next
          end

          if ! tweet.geo.nil?
            logger.debug "Geolocation defined; using it"

            hotspot = {
              "id" => tweet.id,
              "text" => {
                "title"       => "@#{tweet.user.screen_name} (#{tweet.user.name})",
                "description" => tweet.text,
                "footnote"    => since(tweet.created_at)
              },
              # TODO Show local time, or how long ago.
              "anchor" => {
                "geolocation" => {
                  "lat" => tweet.geo.latitude,
                  "lon" => tweet.geo.longitude
                }
              }
            }

            # imageURL is the image in the BIW, the banner at the bottom
            hotspot["imageURL"] = tweet.user.profile_image_uri_https("bigger")

            # Set up an action so the person can go to Twitter and see the
            # actual tweet.  Unfortunately Layar opens web pages
            # internally and doesn't pass them over to a preferred
            # application.
            # See http://layar.com/documentation/browser/api/getpois-response/actions/
            hotspot["actions"] = [{
                "uri"          =>  tweet.uri,
                "label"        => "Read on Twitter",
                "contentType"  => "text/html",
                "activityType" => 27, # Show eye icon
                "method"       => "GET"
              }]

            # icon is the image in the CIW, floating in space
            # By saying "include_entities=1" in the search URL we retrieve more information ...
            # if someone attached a photo to a tweet, show it instead of their profile image
            # Documentation: https://dev.twitter.com/docs/tweet-entities
            if tweet.media?
              # There is media attached.  Look for an attached photo.  Assume only one form of media is attached.
              media = tweet.media.first
              # Assume it's a photo ... if there are more types of media, will need to fix this.
              # Unsure how to get the type of the media out, but right now it's always type = photo
              icon_url = "#{media.media_uri_https}:thumb"
              logger.info "#{tweet.id} has photo attached, icon_url = #{icon_url}"
            else
              icon_url = tweet.user.profile_image_uri_https
            end
            hotspot["icon"] = {
              "url" => icon_url,
              "type" =>  0
            }

            hotspots << hotspot
          end
        end

      rescue Exception => error
        # TODO Catch errors better
        logger.error "Error: #{error}"
      end

    end

    #
    # Add more sources here!
    #

    #
    # Finish by feeding everything back to Layar as JSON.
    #

    # Sort hotspots by distance
    hotspots.sort! {|x, y|
      distance_between(params[:lat], params[:lon], x["anchor"]["geolocation"]["lat"], x["anchor"]["geolocation"]["lon"]) <=>
      distance_between(params[:lat], params[:lon], y["anchor"]["geolocation"]["lat"], y["anchor"]["geolocation"]["lon"])
    }

    logger.info "Hotspots returned: #{hotspots.length}"

    if hotspots.length == 0
      errorcode = 21
      errorstring = "No results found.  Try adjusting your search range and any filters."
      # TODO Customize the error message.
    end

    # In theory we should return up to 50 POIs here (hotspots[0..49]),
    # and if there are more the user would have to page through them.
    # But let's just return them all and let Layar deal with it.
    # TODO Add paging through large sets of results.

    response = {
      "layer"           => layer["layer"],
      "showMessage"     => layer["showMessage"],
      "refreshDistance" => 300,
      "refreshInterval" => 100,
      "hotspots"        => hotspots,
      "errorCode"       => errorcode,
      "errorString"     => errorstring,
    }

    # "NOTE that this parameter must be returned if the GetPOIs request
    # doesn't contain a requested radius. It cannot be used to overrule a
    # value of radius if that was provided in the request. the unit is
    # meter."
    # -- http://layar.com/documentation/browser/api/getpois-response/#root-radius
    if ! params["radius"]
      response["radius"] = radius
    end

  else # The requested layer is not known, so return an error

    errorcode = 22
    errorstring = "No such layer (#{params[:layerName]}) exists"
    response = {
      "layer"           => params[:layerName],
      "refreshDistance" => 300,
      "refreshInterval" => 100,
      "hotspots"        => [],
      "errorCode"       => errorcode,
      "errorString"     => errorstring,
    }
    logger.error errorstring

  end

  # TODO Fail with an error if no lat and lon are given

  response.to_json

end

#
# Helper methods
#

def distance_between(latitude1, longitude1, latitude2, longitude2)
  # Calculate the distance between two points on Earth using the
  # Haversine formula, as taken from https://github.com/almartin/Ruby-Haversine

  latitude1 = latitude1.to_f; longitude1 = longitude1.to_f
  latitude2 = latitude2.to_f; longitude2 = longitude2.to_f

  earthRadius = 6371 # km

  def degrees2radians(value)
    unless value.nil? or value == 0
      value = (value/180) * Math::PI
    end
    return value
  end

  deltaLat = degrees2radians(latitude1  - latitude2)
  deltaLon = degrees2radians(longitude1 - longitude2)
  # deltaLat = degrees2radians(deltaLat)
  # deltaLon = degrees2radians(deltaLon)

  # Calculate square of half the chord length between latitude and longitude
  a = Math.sin(deltaLat/2) * Math.sin(deltaLat/2) +
    Math.cos((latitude1/180 * Math::PI)) * Math.cos((latitude2/180 * Math::PI)) * Math.sin(deltaLon/2) * Math.sin(deltaLon/2);
  # Calculate the angular distance in radians
  c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
  distance = earthRadius * c * 1000 # meters
  return distance

end

def since(t)
  # Give a time, presumably pretty recent, express how long it was
  # in a nice readable way.
  mm, ss = (Time.now - t).divmod(60)
  hh, mm = mm.divmod(60)
  dd, hh = hh.divmod(24)
  if dd > 1
    return "#{dd} days ago"
  elsif dd == 1
    return "#{dd} day and #{hh} hour" + (hh == 1 ? "" : "s") + " ago"
  elsif hh > 0
    return "#{hh} hour" + (hh == 1 ? "" : "s") + " and #{mm} minutes ago"
  else
    return "#{mm} minutes ago"
  end
end
