{-# LANGUAGE OverloadedStrings #-}

--
-- Basic HTTP Reverse Proxy Server. Purposely constrained by not using any HTTP-specific dependencies.
--
-- Current limitations:
--   * Hardcoded backend server port (and no other configuration either really)
--   * Unknown performance
--

module Main where

import System.Environment (getArgs)
import System.IO (Handle, hSetBuffering, BufferMode(NoBuffering))

import Network (listenOn, accept, PortID(..), Socket)
import Network.Socket hiding (recv, accept)
import Network.Socket.ByteString (recv, sendAll)

import Control.Concurrent (forkIO)

import Data.Monoid
import Data.Maybe
import Data.Attoparsec.ByteString (maybeResult, parseWith, parse)
import qualified Data.ByteString as BS

import Types
import Parser
import PrettyPrinter

-- Start up the server listening on the specified port
main :: IO ()
main = do
    args <- getArgs
    let port = fromIntegral (read $ head args :: Int)
    sock <- listenOn $ PortNumber port
    print $ "Listening on " ++ head args
    sockHandler sock

-- Handle requests from the socket concurrently - recursively spawns
-- lightweight green threads.
sockHandler :: Socket -> IO ()
sockHandler sock = do
    (hdl, _, _) <- accept sock
    forkIO $ handler hdl
    sockHandler sock

-- Reads a request, sends it to the "ProxyPass" location and relays the
-- response back to the original client.
handler :: Handle -> IO ()
handler hdl = do
     hSetBuffering hdl NoBuffering
     req <- readRequest hdl 
     res <- proxyRequest req
     BS.hPut hdl $ printResponse res

--
-- External interactions for each request
--
readRequest :: Handle -> IO HttpRequest
readRequest hdl = do
    msg <- BS.hGet hdl 1024
    -- Incrementally get more input from the input handle until the request is done
    parsedReq <- parseWith (BS.hGetNonBlocking hdl 1024) request msg
    return $ fromMaybe nullReq $ maybeResult parsedReq

-- TODO: This is to skip the typechecker for now - Should send an error message
-- back if parsing fails.
nullReq :: HttpRequest
nullReq = undefined

nullRes :: HttpResponse
nullRes = undefined

proxyRequest :: HttpRequest -> IO HttpResponse
proxyRequest req = do

    -- Interrogate DNS for localhost:3000 (Hardcoded for development simplicity)
    addrinfos <- getAddrInfo Nothing (Just "") (Just "3000")
    let serveraddr = head addrinfos

    -- Create the TCP socket and connect to it
    sock <- socket (addrFamily serveraddr) Stream defaultProtocol
    connect sock (addrAddress serveraddr)

    -- Send the request over the TCP socket
    print $ "Sending to backend:   " <> printRequest req 
    sendAll sock $ printRequest req

    -- Get the response back from the backend server
    msg <- recv sock 1024
    print $ "Received from backend:   " <> msg

    -- Close the socket
    close sock

    let res = fromMaybe nullRes $ maybeResult $ parse response msg
    return res
