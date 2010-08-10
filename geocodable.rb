# This module (eventually plugin) provides geocoding methods for AR classes that are geocodable (have a lat/lng column, or a placemark column for mysql/postgres spatial extension data),
# and have descriptive location data (city, state, zip, neighborhood, county, etc).  Its goal is to reduce the number of api calls made to third-party geocoding services,
# by relying on local data first, when possible.

# As an example, assume we have a class called Event which has a zip column.  After a user creates a new Event and 
# assigns it a zip code, we'd like to record the precise geo coordinates of the event for proximity searches, so that other users
# may find events in their area.
# 
# Prevailing geocoding services allow calls to be made at a fixed, finite rate.  For a high volume model, that rate may be exceeded regularly.
# We can use this module to reduce the rate at which calls to the api are made by attempting to geocode from local data first.
# More specifically, we scan the database for geocoded records with
# similar descriptive locations, and if they exist we derive the spatial data from those records, instead of through an api call.

require 'ym4r/google_maps/geocoding'

      

module TweetyJobs

    module GeoCodable
      
      
      unless Object.constants.include? "GEOCODABLE_DEFINED"
        GEO_ALLOW_ZIP_WILDCARDS = true # If an exact zip match isn't found, allow similar zips to be used as a LAST RESORT
        GEOCODABLE_DEFINED = 'yup'
        GEO_KMS_PER_MILE = 1.609
        GEO_NMS_PER_MILE = 0.868976242
        GEO_EARTH_RADIUS_IN_MILES = 3963.19
        GEO_EARTH_RADIUS_IN_KMS = GEO_EARTH_RADIUS_IN_MILES * GEO_KMS_PER_MILE
        GEO_EARTH_RADIUS_IN_NMS = GEO_EARTH_RADIUS_IN_MILES * GEO_NMS_PER_MILE
        GEO_DEFAULT_UNITS = :miles
      end
      
      class GeocodableLogger < Logger

        def format_message(severity, timestamp, progname, msg)
          "#{timestamp.to_formatted_s(:db)} #{severity} #{msg}\n" 
        end
        
      end 
      
      # We use this class to make lat/lng objects for comparisons
      class LatLng
        
        attr_accessor :lat, :lng
        
        def initialize(obj)
          begin
            @lat = obj.lat
            @lng = obj.lng
          rescue
            raise "Geocodable::LatLng object's lat or lng couldn't be set from associated object #{obj.inspect} - make sure it has lat & lng atts"
          end
        end
        
      end
      

      Logger = GeocodableLogger.new(File.join(RAILS_ROOT,"log","geocodable.log"))
      
      
      
      def self.included( recipient )
        recipient.extend( GeoCodableClassMethods )
        recipient.class_eval do
          include Ym4r::GoogleMaps
          include GeoCodableInstanceMethods
          
          acts_as_mappable \
            :default_units       => :miles,
            :default_formula     => :sphere,
            :distance_field_name => :distance
          
          before_validation :geocode
          
          named_scope       :ungeocoded,  :conditions => "lat IS NULL AND lng IS NULL"
          named_scope       :geocodable,  :conditions => "(location IS NOT NULL AND location <> '') OR (zip IS NOT NULL AND zip <> '')"
          named_scope       :geocoded,    :conditions  => "lat IS NOT NULL AND lng IS NOT NULL"

          
          @@geocoding_required_attributes = [:zip, :location, :lat, :lng]
          
          @@geocoding_indirect_attributes = [:zip, :location]
          
          @@location_title_attributes     = [:address_1, :address_2, :city, :zip] & recipient.columns.map{|c| c.name.to_sym}
          
          @@spherical_unit_multipliers = {
            :kms    => GEO_EARTH_RADIUS_IN_KMS,
            :nms    => GEO_EARTH_RADIUS_IN_NMS,
            :miles  => GEO_EARTH_RADIUS_IN_MILES
          }
          
          @@spherical_unit_multipliers.default = GEO_EARTH_RADIUS_IN_MILES
          
          cattr_accessor :geocoding_required_attributes,
                         :spherical_unit_multipliers,
                         :error,
                         :location_title_attributes,
                         :geocoding_attributes_present,
                         :geocoding_indirect_attributes
                         
          attr_accessor  :normalized_location

        end
      end

      module GeoCodableClassMethods
        
        # This is for debugging more than anything
        def geocode(location, options={})
          results = Geocoding::get(location, options)
          GeoCodable::Logger.debug results.inspect
          return results
        end
        
        def geocode_all
          ungeocoded.geocodable.each{|obj| obj.geocode }
        end

        def supports_geocoding?
          @@geocoding_attributes_present ||= ((column_names & geocoding_required_attributes.map(&:to_s)).uniq.size == geocoding_required_attributes.size)
        end

        def parse_geocoding_error(results)
          @@error = \
            case results.status
              when Geocoding::GEO_SUCCESS             : "GEO_SUCCESS"         # this would not happen ever, ever I hope
              when Geocoding::GEO_MISSING_ADDRESS     : "GEO_MISSING_ADDRESS"
              when Geocoding::GEO_UNKNOWN_ADDRESS     : "GEO_UNKNOWN_ADDRESS"
              when Geocoding::GEO_UNAVAILABLE_ADDRESS : "GEO_UNAVAILABLE_ADDRESS"
              when Geocoding::GEO_BAD_KEY             : "GEO_BAD_KEY"
              when Geocoding::GEO_TOO_MANY_QUERIES    : "GEO_TOO_MANY_QUERIES"
              when Geocoding::GEO_SERVER_ERROR        : "GEO_SERVER_ERROR"
              else "UNKNOWN"
            end
            return @@error
        end
        
        def units_sphere_multiplier(units)
          spherical_unit_multipliers[units.to_sym]
        end


        def deg2rad(degrees)
          degrees.to_f / 180.0 * Math::PI
        end

        def rad2deg(rad)
          rad.to_f * 180.0 / Math::PI
        end


        def sphere_distance_between(from, to, options={})
          # take whatever AR object and strip it down to a an object with only lat/lng as atts, for comparison,
          # as the args from & to may be entirely different objects to begin with
          from, to = GeoCodable::LatLng.new(from), GeoCodable::LatLng.new(to)
          return 0.0 if from == to
          units   = options[:units] || GEO_DEFAULT_UNITS
          begin
            units_sphere_multiplier(units) *
              Math.acos( Math.sin(deg2rad(from.lat)) * Math.sin(deg2rad(to.lat)) +
              Math.cos(deg2rad(from.lat)) * Math.cos(deg2rad(to.lat)) *
              Math.cos(deg2rad(to.lng) - deg2rad(from.lng)))
          rescue Errno::EDOM 
            return 0.0
          end
        end

      end # class methods

      module GeoCodableInstanceMethods
        
        def geo_coords
          [lat, lng]
        end
        
        # A string representing the objects geocoding status for debugging
        def geo_info
          "GeoInfo for #{self.cache_key}: " + self.class.geocoding_required_attributes.map{|a| value = self.send(a.to_sym).to_s;[a.to_s, value.blank? ? "empty" : value ].join(": ")}.join(", ")
        end
        
        def set_lat_lng(*coords)
          self.lat = coords[0]
          self.lng = coords[1]
        end
        
        def inherit_geodata_from_geocoding_results(results)
          first_result = results.first
          self.lng = first_result.latlon[1]
          self.lat = first_result.latlon[0]
          self.city =  first_result.sub_administrative_area if self.attribute_names.include?("city")
          return first_result
        end
        
        def inherit_geodata_from_zip(zip_code)
          raise "#{zip_code.inspect} must have class Zip" unless zip_code.is_a?(Zip)
          set_lat_lng(zip_code.latitude, zip_code.longitude)
          if zip_complete?
            self.zip     = zip_code.zip_code
          end
          self.location  = zip_code.to_location.to_s
          return self
        end
        
        # Inherit as much geodata from obj as possible - return false if it can't be done
        def inherit_geodata_from(obj)
          GeoCodable::Logger.debug "Setting geoattributes from #{obj.inspect}"
          return false if obj.nil?
          if obj.is_a?(Zip)
            inherit_geodata_from_zip(obj)
          elsif obj.is_a?(self.class)
            set_lat_lng(obj.lat, obj.lng)
            self.placemark = obj.placemark if self.attributes.include?("placemark")
          elsif obj.is_a?(Array)
            inherit_geodata_from_geocoding_results(obj)
          else
            return false
          end
        end
        
        # Does the location contain more than just spaces and punctuation
        def location_blank?
          location_significant_chars.size == 0
        end
        
        def full_location
          location_blank? ? self.class.location_title_attributes.map{|a| self.try(a)}.compact.join(", ") : location
        end
        
        def location_significant_chars
           @normalized_location ||= self.location.to_s.gsub(/[^a-zA-Z0-9]+/,'')
        end

        def geocoded?
          !!(lat && lng)
        end

        alias :already_geocoded? :geocoded?

        def location_display
          location_blank? ? Zip.location_for(self.zip) : location
        end
        
        def spherical_distance_to(lat_lng_obj)
           "%0.2f" % self.class.distance_between(self, lat_lng_obj)
        end
        
        def has_geocodable_attributes?
          !self.class.geocoding_indirect_attributes.map{|a| self.try(a) }.compact.blank?
        end
        
        def location_ignored?
          TweetyJobs::Settings[:geocoding][:ignore].to_a.include?(location) rescue false
        end
        
        # Is the object in a state in which it can be geocoded 
        # (has the right attributes, hasn't been geocoded already, has a location or zip 
        # and the location isn't in our "ignore list")
        def geocodable?
          self.class.supports_geocoding? &&
          !already_geocoded? &&
          has_geocodable_attributes? && 
          !location_ignored?
        end
  
        # A record with the same location text and a non-null lat/lng
        def best_location_match
          # TODO: Refactor so sql counts frequency instead of slow ruby array operations
          matches = self.class.find(:all, :conditions => ["location = ? AND location IS NOT NULL AND lat IS NOT NULL AND lng IS NOT NULL", full_location])
          logger.debug "Location based matches #{matches.inspect}"
          # Sort so most common record appears first
          matches.compact.sort{|b,a| matches.select{|m| m == a}.size <=> matches.select{|m| m == b}.size }.first
        end
  
        # Does another record have the same location text and is already geocoded?
        def location_cached?
          GeoCodable::Logger.debug "Attempting to geocode from previously located records with the same location #{full_location}"
          @location_match = best_location_match
          if @location_match
            inherit_geodata_from(@location_match)
            return true
          else
            return false
          end
        end
       
        #TODO
        #def valid_zip?
        #end
        
        # First N digits of zip before dash
        def major_zip
          @primary_zip ||= self.zip.to_s.match(/[^0-9]{0,5}/).to_s
        end
        
        # This will return false for an zip shorter than 5 digits and 
        # true for any zip >= 5 since we've already truncated to 5 in major_zip
        def zip_complete?
          major_zip.length == 5
        end
        
        
        # @primary_zip is populated anew on every call of zip_complete
        # TODO: Refactor - this is unnecessarily opaque
        def zip_for_search
          zip_complete? ? @primary_zip : @primary_zip + "%"
        end

        # Do zips exist in our zips table which match the given search string?
        # String will be wildcarded if it's less than 5 characters long
        # as zip sig figs are somewhat bound to geography (90210 should be closer to 90245 than to 19123)
        def zip_match(search_zip=nil)
          search_zip ||= zip_for_search
          # TODO: Optimize for full zips, since LIKE will be slow in that case
          GeoCodable::Logger.debug "Looking for zip code #{search_zip} to derive geo attributes from"
          zip_code         = Zip.find(:first, :conditions => ["zip_code LIKE ?", search_zip ])
          if zip_code
            GeoCodable::Logger.debug "Zip match found #{zip_code.cache_key}"
            inherit_geodata_from(zip_code)
            self.save(false)
            return zip_code
          else
            return false
          end
        end
  
        # Start with the full zip and truncate iteratively until we find a zip which is similar to this object's zip
        # Quit when we find a match or the search string is shorter than 2 characters
        def iterative_zip_match?(options={})
          GeoCodable::Logger.debug "Attempting last ditch zip match based on the first few digits of the zip"
          # disllow iterative zip searches on a case by case basis also
          options[:iterative] ||= true
          search_zip = major_zip
          zip_match  = zip_match(search_zip)
          while GeoCodable::GEO_ALLOW_ZIP_WILDCARDS && search_zip.length >= 2 && !zip_match && options[:iterative]
            #Knock a digit off of search_zip and re-search
            search_zip = search_zip[0..(search_zip.length - 2)]
            zip_match  = zip_match(search_zip)
          end
          return zip_match
        end

        def geocoding_results(string=nil)  
          results = Geocoding::get(geocoding_string(string), :output => 'json')
          first_result = results.first
          GeoCodable::Logger.debug "#{results.inspect} json results from api: First Result -> #{first_result.inspect}"
          return results
        end
        
        def geocoding_string(string=nil)
          string || self.full_location
        end
        
        # Attempt to geocode using the zip or location and local data.
        # Return true if an accurate match was found
        # Return false if it isn't possible
        def geocode_indirectly
          GeoCodable::Logger.debug "Attempting to geocode #{self.geo_info} indirectly"
          # If there is no location, we know there is a zip (from the has_geocodable_attributes? method),
          # so look for a direct zip match
          if location_blank?
            GeoCodable::Logger.debug "Location is blank"
            return zip_match
          # If there is no zip, but there is a location,
          # We look for other records with the same location that have geo data
          elsif zip.blank?
            GeoCodable::Logger.debug "Zip is blank"
            return location_cached?
          # If both attributes are present, try to use
          # the location string first, then try using the zip code
          else
            GeoCodable::Logger.debug "Zip and location are intact"
            return (location_cached? || zip_match?)
          end
        end
        
        # Use our third party api to geocode based on a passed
        # string or our default location text (the location attribute here)
        def geocode_with_api(string=nil)
          results = geocoding_results(geocoding_string(string))
          if results.status == Geocoding::GEO_SUCCESS
            inherit_geodata_from(results)
            return true
          else
            error = self.class.parse_geocoding_error(results)
            GeoCodable::Logger.error "Geocoding didn't work #{error.inspect}"
            # All else failed - if the zip isn't blank, we'll find a zip that looks similar
            return false
          end
        end
        

        # All of the other geocoding methods compounded.
        # Ensure geocodability, try indirect geocoding, then direct geocoding
        # with the api, then a loose zip similarity search as a last resort (if desired)
        def geocode(string=nil)
          GeoCodable::Logger.debug "Geocoding #{self.geo_info}"
          if !geocodable?
            GeoCodable::Logger.error "#{self.cache_key} is not geocodable"
          elsif geocode_indirectly
            return true
          elsif geocode_with_api
            return true
          elsif iterative_zip_match?
            return true
          else
            return false
          end
        end
        
        
        
        # Find sibling records within "distance" miles of self
        def find_within_distance(distance)
          qualified_lat_column_name = "lat"
          qualified_lng_column_name = "lng"
          lat = self.lat
          lng = self.lng
            multiplier = 1
            sql=<<-SQL_END 
                  SELECT *,(ACOS(least(1,COS(#{lat})*COS(#{lng})*COS(RADIANS(#{qualified_lat_column_name}))*COS(RADIANS(#{qualified_lng_column_name}))+
                  COS(#{lat})*SIN(#{lng})*COS(RADIANS(#{qualified_lat_column_name}))*SIN(RADIANS(#{qualified_lng_column_name}))+
                  SIN(#{lat})*SIN(RADIANS(#{qualified_lat_column_name}))))*#{multiplier}) from #{self.class.table_name} AS distance WHERE distance <= #{distance}
                  SQL_END
            self.class.find_by_sql(sql.gsub(/\s{2,}/," "))#, :conditions => ["id = ?", self.id])
        end

      end # instance methods
    end
    
end

