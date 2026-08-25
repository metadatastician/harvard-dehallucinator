{-# LANGUAGE OverloadedStrings #-}
module Main where

import System.Environment (getArgs)
import System.IO
import Text.Read (readMaybe)
import Control.Monad (when)

stateFile :: FilePath
stateFile = "../state/state.txt"

data State = State {
    totalItems :: Int,
    completed :: Int,
    attempts :: Int,
    status :: String
} deriving (Show)

readState :: IO State
readState = do
    contents <- readFile stateFile
    let linesOfFile = lines contents
    case linesOfFile of
        [t, c, a, s] -> return $ State (read t) (read c) (read a) s
        _ -> error "Corrupted State File"

writeState :: State -> IO ()
writeState state = do
    let content = unlines [show (totalItems state), show (completed state), show (attempts state), status state]
    writeFile stateFile content

initState :: Int -> IO ()
initState total = do
    let initialState = State total 0 0 "RUNNING"
    writeState initialState
    putStrLn $ "Initialized Harvard Engine State with " ++ show total ++ " items."

incrementAttempt :: IO ()
incrementAttempt = do
    st <- readState
    let newAttempts = attempts st + 1
    let newStatus = if newAttempts > totalItems st + 5 then "EMERGENCY_STOP" else status st
    let newState = st { attempts = newAttempts, status = newStatus }
    writeState newState
    when (newStatus == "EMERGENCY_STOP") $
        putStrLn "CIRCUIT BREAKER TRIGGERED: Infinite loop detected. Manual intervention required."

updateCompleted :: Int -> IO ()
updateCompleted remaining = do
    st <- readState
    let newCompleted = totalItems st - remaining
    let newStatus = if remaining == 0 then "COMPLETE" else status st
    let newState = st { completed = newCompleted, status = newStatus }
    writeState newState
    putStrLn $ "Updated progress: " ++ show newCompleted ++ "/" ++ show (totalItems st) ++ " completed."

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["init", total] -> initState (read total)
        ["attempt"] -> incrementAttempt
        ["update", remaining] -> updateCompleted (read remaining)
        _ -> putStrLn "Usage: Engine [init total | attempt | update remaining]"
