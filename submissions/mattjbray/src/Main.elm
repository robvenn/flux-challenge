module Main where

import Array exposing (Array)
import Effects exposing (Effects)
import Html exposing (Html, button, div, h1, h3, h6, li, text, ul)
import Html.Attributes exposing (class, classList, style)
import Html.Events exposing (onClick)
import Http
import Json.Decode as Json exposing ((:=))
import Maybe exposing (andThen)
import StartApp
import Task

--
-- Config
--

scrollSpeed = 2
nbSlots = 5

--
-- Wiring
--

app =
  StartApp.start
    { init = init darthSidious
    , update = update
    , view = view
    , inputs = [Signal.map SetWorld currentWorld]
    }

main =
  app.html

port tasks : Signal (Task.Task Effects.Never ())
port tasks =
  app.tasks

-- index.html creates a websocket and calls this port whenever a message is
-- received.
port currentWorld : Signal (Maybe World)

--
-- Models
--

type alias Model =
  { -- Obi-Wan's current location
    world:Maybe World
    -- The slots in view, which may contain dark jedis
  , jediSlots:Array (Maybe Jedi)
    -- Current scroll position. When we fire off a request to fetch a new jedi,
    -- we store the current index of the slot in which to inject the new jedi as
    -- well as the current scroll position. When the request completes, the
    -- index is adjusted for any scrolling which happened since the request
    -- started.
  , scrollPos:Int
    -- List of HTTP requests that have been made for jedis. When a request
    -- completes, it is removed from the list. On scrolling, requests for
    -- out-of-view jedis are aborted and removed from this list.
  , jediRequests:List JediRequest
  , nextRequestId:Int
  }

type alias World =
  { id:Int
  , name:String
  }

type alias Jedi =
  { id:Int
  , name:String
  , homeworld:World
  , master:Maybe JediUrl
  , apprentice:Maybe JediUrl
  }

type alias JediUrl =
  { id:Int
  , url:String
  }

type alias JediRequest =
  { id:Int
  , insertPos:Int
  , scrollPos:Int
  , abort:Effects Action}

type ScrollDir
  = Up
  | Down

darthSidious : JediUrl
darthSidious =
  { id=3616
  , url="http://localhost:3000/dark-jedis/3616"
  }

init : JediUrl -> (Model, Effects Action)
init jediUrl =
  fetchJedi initModel (nbSlots // 2) jediUrl

initModel : Model
initModel =
  { world = Nothing
  , jediSlots = Array.repeat nbSlots Nothing
  , scrollPos = 0
  , jediRequests = []
  , nextRequestId = 0
  }

--
-- Actions
--

type Action
  = SetWorld (Maybe World)
  | SetJedi JediRequest
            (Maybe Jedi)
  | Scroll ScrollDir
  | NoAction

--
-- Update
--

update : Action -> Model -> (Model, Effects Action)
update action model =
  case action of
    SetJedi request newJedi ->
      setJedi request newJedi model

    SetWorld mWorld ->
      pure { model | world <- mWorld }

    Scroll dir ->
      doScroll model dir

    NoAction ->
      pure model

--
-- Business logic
--

{-| Set the jedi at request.insertPos, adjusting for scrolling, remove the
completed request from the list, and fetch the jedis before/after the new jedi
if required
-}
setJedi : JediRequest -> Maybe Jedi -> Model -> (Model, Effects Action)
setJedi request newMJedi model =
  -- We adjust the position in which to inject the new jedi to account for
  -- any scrolling since the jedi was requested.
  let adjustedPos =
        adjustPos request.insertPos
                  request.scrollPos
                  model.scrollPos
      newJediSlots =
        if inBounds adjustedPos model.jediSlots
          then Array.set adjustedPos newMJedi model.jediSlots
          -- Don't update the model if this jedi has been scrolled off-screen.
          else model.jediSlots
      model' = { model | jediRequests <- removeRequest request model.jediRequests
                       , jediSlots <- newJediSlots }
  in
      maybeFetchJedisAround adjustedPos model'

{-| Extract requests for jedis that are no longer in view and need to be
aborted.
-}
abortRequests : Model -> (Model, Effects Action)
abortRequests model =
  let (newRequests, requestsToAbort) =
        List.partition
          (\request ->
             (inBounds (adjustPos request.insertPos
                        request.scrollPos
                        model.scrollPos)
             model.jediSlots))
          model.jediRequests
      aborts = List.map .abort requestsToAbort
  in
      ( { model | jediRequests <- newRequests }
      , Effects.batch aborts )

{-|  Scrolling logic. If we can scroll (see `canScroll`):
* remove `scrollSpeed` jedis from the beginning (end) of the slots list,
* add `scrollSpeed` empty slots to the end (beginning),
* abort any requests for jedis that are now out of view, and
* if the first (last) jedi has a master (an apprentice), fire off a new jedi
  request.
-}
doScroll : Model -> ScrollDir -> (Model, Effects Action)
doScroll model dir =
  if not (canScroll dir model.jediSlots)
    then pure model
    else
      let slotsLength =
            Array.length model.jediSlots

          emptySlots =
            Array.repeat scrollSpeed Nothing

          (newJedis, newScrollPos, endJediPos) =
            case dir of
              Up ->
                ( Array.append emptySlots (Array.slice 0 (slotsLength - scrollSpeed) model.jediSlots)
                , model.scrollPos - scrollSpeed
                , scrollSpeed
                )
              Down ->
                ( Array.append (Array.slice scrollSpeed slotsLength model.jediSlots) emptySlots
                , model.scrollPos + scrollSpeed
                , slotsLength - scrollSpeed - 1
                )

      in
          pure { model | jediSlots <- newJedis
                       , scrollPos <- newScrollPos }
            >>= abortRequests
            >>= maybeFetchJedisAround endJediPos

fetchJedi : Model -> Int -> JediUrl -> (Model, Effects Action)
fetchJedi model insertPos {url} =
  let (sendTask, abortTask) =
        Http.getWithAbort decodeJedi url

      abortEffect =
        abortTask
          |> Task.toMaybe
          |> Task.map (\_ -> NoAction)
          |> Effects.task

      request =
        { id = model.nextRequestId
        , insertPos = insertPos
        , scrollPos = model.scrollPos
        , abort = abortEffect }

      sendEffect =
        sendTask
          |> Task.toMaybe
          |> Task.map (SetJedi request)
          |> Effects.task

  in
      ( { model | jediRequests <- request :: model.jediRequests
                , nextRequestId <- model.nextRequestId + 1 }
      , sendEffect )

{-| Check whether we have jedis around the jedi at `pos`, and fetch them if we
don't.
-}
maybeFetchJedisAround : Int -> Model -> (Model, Effects Action)
maybeFetchJedisAround pos model =
  let (model' , effects)  = maybeFetchJedi model  pos (pos - 1) .master
      (model'', effects') = maybeFetchJedi model' pos (pos + 1) .apprentice
  in (model'', Effects.batch [effects, effects'])

maybeFetchJedi : Model -> Int -> Int -> (Jedi -> Maybe JediUrl) -> (Model, Effects Action)
maybeFetchJedi model pos nextPos getNextUrl =
  let
    mNext =
      if needJediAt nextPos model
        then Array.get pos model.jediSlots `andThenAndThen` getNextUrl
        else Nothing
  in
    case mNext of
      Just nextUrl ->
        fetchJedi model nextPos nextUrl
      Nothing ->
        pure model

--
-- Helpers
--

adjustPos : Int -> Int -> Int -> Int
adjustPos pos oldScrollPos newScrollPos =
  let offset = oldScrollPos - newScrollPos
  in pos + offset

removeRequest : JediRequest -> List JediRequest -> List JediRequest
removeRequest request requests =
  List.filter (\ r -> r /= request) requests

haveJediAt : Int -> Model -> Bool
haveJediAt pos {jediSlots} = Array.get pos jediSlots /= Just Nothing

needJediAt : Int -> Model -> Bool
needJediAt pos model =
  inBounds pos model.jediSlots && not (haveJediAt pos model)

{-| Return True if the first (last) jedi in the list has an apprentice (master)
AND we would have at least one jedi in view after the scroll.
-}
canScroll : ScrollDir -> Array (Maybe Jedi) -> Bool
canScroll upOrDown jediSlots =
  let loadedJedis = Array.filter notNothing jediSlots
      (firstOrLast, apprenticeOrMaster) =
        case upOrDown of
          Up ->
            ( Array.get 0
            , .master)
          Down ->
            ( (\jedis -> Array.get (Array.length jedis - 1) jedis)
            , .apprentice)
      mJedi = firstOrLast loadedJedis
      next = mJedi `andThenAndThen` apprenticeOrMaster
      jediInView = jediSlots
                     |> (case upOrDown of
                           Up -> Array.slice 0 -scrollSpeed
                           Down -> Array.slice scrollSpeed (Array.length jediSlots))
                     |> any notNothing
  in notNothing next && jediInView

onWorld : Maybe Jedi -> Maybe World -> Bool
onWorld mJedi mWorld =
  case mMap2 (,) mWorld mJedi of
    Just (world, jedi) ->
      jedi.homeworld.id == world.id
    Nothing -> False

--
-- Views
--

view : Signal.Address Action -> Model -> Html
view address {world, jediSlots} =
  div [ class "css-root" ]
    [ viewPlanetMonitor world
    , viewJediList address jediSlots world
    ]

viewPlanetMonitor : Maybe World -> Html
viewPlanetMonitor mWorld =
  h1 [ class "css-planet-monitor" ]
    [ text ("Obi-Wan currently "
            ++
            (case mWorld of
               Just {name} -> "on " ++ name
               Nothing -> "in transit"))
    ]

viewJediList : Signal.Address Action -> Array (Maybe Jedi) -> Maybe World -> Html
viewJediList address jediSlots mWorld =
    div [ class "css-scrollable-list" ]
      [ ul [ class "css-slots" ]
          (List.map (viewJedi mWorld)
                    (Array.toList jediSlots))
      , viewScrollButtons address jediSlots mWorld
      ]

viewJedi : Maybe World -> Maybe Jedi -> Html
viewJedi mWorld mJedi =
  li
    [ class "css-slot"
    , style (if mJedi `onWorld` mWorld
               then [("color", "red")]
               else [])
    ]
    (case mJedi of
       Nothing -> []
       Just jedi ->
         [ h3 [] [ text jedi.name ]
         , h6 [] [ text jedi.homeworld.name ]
         ]
    )

viewScrollButtons : Signal.Address Action -> Array (Maybe Jedi) -> Maybe World -> Html
viewScrollButtons address jediSlots mWorld =
  let scrollDisabled = any (flip onWorld mWorld) jediSlots
  in
    div [ class "css-scroll-buttons" ]
      (List.map
         (viewScrollButton address scrollDisabled jediSlots)
         [ Up, Down ])

viewScrollButton : Signal.Address Action -> Bool -> Array (Maybe Jedi) -> ScrollDir -> Html
viewScrollButton address scrollDisabled jediSlots dir =
  let className =
        case dir of
          Up ->
            "css-button-up"
          Down ->
            "css-button-down"

      enabled = not scrollDisabled && canScroll dir jediSlots

      classes = classList [ (className, True)
                          , ("css-button-disabled", not enabled)
                          ]

      clickHandler = onClick address (Scroll dir)
  in
      button
        (if enabled
           then [classes, clickHandler]
           else [classes])
        []

--
-- Decoders
--

decodeJedi : Json.Decoder Jedi
decodeJedi =
  Json.object5 Jedi
    ("id" := Json.int)
    ("name" := Json.string)
    ("homeworld" := decodeWorld)
    ("master" := decodeJediUrl)
    ("apprentice" := decodeJediUrl)

decodeWorld : Json.Decoder World
decodeWorld =
  Json.object2 World
    ("id" := Json.int)
    ("name" := Json.string)

-- If id is null return Nothing, otherwise return a JediUrl
decodeJediUrl : Json.Decoder (Maybe JediUrl)
decodeJediUrl =
  ("id" :=
     (Json.oneOf
        [ Json.map Just Json.int
        , Json.null Nothing
        ]))
  `Json.andThen`
    (\mId ->
       case mId of
         Just id ->
           Json.object1 (\url -> Just (JediUrl id url))
             ("url" := Json.string)
         Nothing ->
           -- id was null, return Nothing
           Json.succeed Nothing)

--
-- Lib
--

inBounds : Int -> Array x -> Bool
inBounds pos slots =
  pos >= 0 && pos < Array.length slots

notNothing : Maybe x -> Bool
notNothing maybe =
  case maybe of
    Nothing -> False
    Just _  -> True

isNothing : Maybe x -> Bool
isNothing = not << notNothing

{-| Naive Array.any
 -}
any : (a -> Bool) -> Array a -> Bool
any pred array = Array.length (Array.filter pred array) > 0

{-| Maybe.map2 from elm-lang/core 3.0.0
 -}
mMap2 : (a -> b -> value) -> Maybe a -> Maybe b -> Maybe value
mMap2 func ma mb =
  case (ma,mb) of
    (Just a, Just b) -> Just (func a b)
    _ -> Nothing

{-| The same as Maybe.andThen, but when your input is a nested Maybe.
 -}
andThenAndThen : Maybe (Maybe a) -> (a -> Maybe b) -> Maybe b
andThenAndThen mmValue f =
  mmValue `andThen` flip andThen f

{-| Monadic pure: lift a Model to a (Model, Effects Action).
-}
pure : a -> (a, Effects Action)
pure model = (model, Effects.none)

{-| Monadic bind: compose effectful computations.
-}
(>>=) : (a, Effects Action) -> (a -> (a, Effects Action)) -> (a, Effects Action)
(model, effects) >>= f =
  let (model', effects') = f model
  in
      (model', Effects.batch [effects, effects'])
