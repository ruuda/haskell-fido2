{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedLists #-}

module Main
  ( main,
  )
where

import Control.Concurrent.STM (TVar)
import qualified Control.Concurrent.STM as STM
import Control.Monad.IO.Class (liftIO)
import Crypto.Fido2 as Fido2
import qualified Crypto.Random as Random
import Data.Aeson.QQ (aesonQQ)
import Data.ByteString (ByteString)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.ByteString.Base64.URL as Base64
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text.Encoding as Text
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Network.Wai.Middleware.Static (staticPolicy, addBase)
import qualified Web.Cookie as Cookie
import Web.Scotty (ScottyM)
import qualified Web.Scotty as Scotty
import qualified Network.HTTP.Types.Status as Status
import Data.List.NonEmpty


newSession :: TVar Sessions -> IO Cookie.SetCookie
newSession sessions = do
  sessionId <- UUID.nextRandom
  STM.atomically $ do
    contents <- STM.readTVar sessions
    STM.writeTVar sessions $ Map.insert sessionId Unauthenticated contents

  pure $ Cookie.defaultSetCookie
    { Cookie.setCookieName = "session"
    , Cookie.setCookieValue = UUID.toASCIIBytes sessionId
    , Cookie.setCookieSameSite = Just Cookie.sameSiteStrict
    , Cookie.setCookieHttpOnly = True
    -- Might not work on the dev server. Let's see if localhost is always
    -- a secure origin. (Arian says it is for the FIDO standard, but it
    -- might not apply to this field.) Otherwise, we can use mkcert to
    -- get a HTTPS setup for localhost.
    , Cookie.setCookieSecure = True
    }

-- Session data that we store for each user.
--
--                         +---> Registering ----+
--                         |                     |
--      Unauthenticated ---+                     +---> Authenticated
--                         |                     |
--                         +---> Authenticating -+
--
--  Whether we consider Authenticated right after Registering is a design
--  choice. Should be safe to do? But let's double check that the spec
--  actually guarantees that you own the public key after registering.
data Session
  = Unauthenticated
  | Registering UserId Challenge
  | Authenticating Challenge
  | Authenticated UserId


type Sessions = Map UUID Session

type Users = Map UserId User

data User


app :: TVar Sessions -> TVar Users -> ScottyM ()
app sessions users = do
  Scotty.middleware (staticPolicy (addBase "dist"))

  Scotty.get "/register/begin" $ do
    challenge <- liftIO $ newChallenge
    identifier <- liftIO $ newUserId
    Scotty.json $
      PublicKeyCredentialCreationOptions
        { rp =
            PublicKeyCredentialRpEntity
              { id = Nothing,
                name = "ACME"
              },
          user =
            PublicKeyCredentialUserEntity
              { id = identifier,
                displayName = "Hello",
                name = "Hello"
              },
          challenge = challenge,
          pubKeyCredParams = [PublicKeyCredentialParameters {
            typ = PublicKey,
            alg = ES256
          }], -- EDIT: NO Is empty supported?
          timeout = Nothing,
          excludeCredentials = Nothing,
          authenticatorSelection = Just AuthenticatorSelectionCriteria {
            authenticatorAttachment = Nothing,
            residentKey = Just ResidentKeyDiscouraged,
            userVerification = Just UserVerificationRequired
          },
          attestation = Nothing
        }

  Scotty.post "/register/complete" $ do
    credential <- Scotty.jsonData @(PublicKeyCredential AuthenticatorAttestationResponse)
    liftIO . print $ credential
    {-
    case session of
      Unauthenticated -> do
        Scotty.setStatus  Status.status401
        pure ()
      Registering challenge -> do
        let clientData' :: ClientData = Fido2.clientData (response credential)
        let challenge' = Fido2.challenge (clientData' :: ClientData)
        -- step 3
        if Fido2.typ (clientData' :: ClientData) /= Createj
        then do
          Scotty.setStatus Status.status401
          Scotty.text "typ mismatch"
        -- step 4
        else if challenge /= (Challenge  challenge')
        then do
          Scotty.setStatus Status.status401
          Scotty.text "challenge mismatch"
        -- step 5
        else if (Fido2.origin clientData') /= "http://localhost:8080"
        then do
          Scotty.setStatus Status.status401
          Scotty.text "origin mismatch"
        else do
          -- skip step 6 for now
          Scotty.writeSession Authenticated
          pure ()
          -- step 7 we get for free
          --
      Authenticating challenge -> do
        -- We should merge /login/complete and /register/complete. Same code here. Dual
        Scotty.setStatus  Status.status401
        Scotty.text "authenticating"
        pure ()
      Authenticated -> pure ()
      -}

  Scotty.get "/login/begin" $ do
    challenge <- liftIO $ newChallenge
    -- Scotty.writeSession . Registering . Challenge $ challenge
    identifier <- liftIO $ newUserId
    Scotty.json $
      PublicKeyCredentialRequestOptions
        { rpId = Nothing,
          timeout = Nothing,
          challenge = challenge,
          allowCredentials = Nothing,
          userVerification = Nothing
        }
    pure ()

  Scotty.post "/login/complete" $ do
    credential <- Scotty.jsonData @(PublicKeyCredential AuthenticatorAssertionResponse)
    liftIO . print $ credential
    pure ()

main :: IO ()
main = do
  sessions <- STM.newTVarIO Map.empty
  users <- STM.newTVarIO Map.empty

  putStrLn "You can view the web-app at: http://localhost:8080/index.html"
  Scotty.scotty 8080 (app sessions users)
