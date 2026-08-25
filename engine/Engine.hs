-- SPDX-License-Identifier: MPL-2.0
-- The Harvard Dehallucinator state engine.
--
-- THE GUARANTEE: `completed` and `status` are only ever DERIVED from
-- engine/verify_register.sh. No caller can assert progress. There is no code
-- path from a command-line argument to the string "COMPLETE".
--
-- The original engine took `remaining` as a parameter, which put the progress
-- number back inside the agent's writable space -- the exact Von Neumann
-- collapse this project exists to prevent. That command has been removed.
module Main where

import Control.Exception (SomeException, try)
import Data.Char (isSpace)
import System.Directory
    (doesDirectoryExist, doesFileExist, getCurrentDirectory, renameFile)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>), takeDirectory)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

-- ---------------------------------------------------------------- state ----

data State = State
    { totalItems :: Int
    , completed  :: Int
    , attempts   :: Int
    , status     :: String
    } deriving (Show)

statusRunning, statusComplete, statusStop :: String
statusRunning  = "RUNNING"
statusComplete = "COMPLETE"
statusStop     = "EMERGENCY_STOP"

-- How many attempts beyond totalItems before the breaker trips.
attemptSlack :: Int
attemptSlack = 5

trim :: String -> String
trim = f . f where f = reverse . dropWhile isSpace

-- ----------------------------------------------------------- locating ------
-- Never cwd-relative. The original hardcoded "../state/state.txt", so the
-- engine only worked when invoked from engine/.

isRoot :: FilePath -> IO Bool
isRoot d = do
    v <- doesFileExist (d </> "engine" </> "verify_register.sh")
    s <- doesDirectoryExist (d </> "state")
    return (v && s)

findRoot :: IO (Either String FilePath)
findRoot = do
    override <- lookupEnv "HARVARD_ROOT"
    case override of
        Just p -> do
            ok <- isRoot p
            return $ if ok
                then Right p
                else Left ("HARVARD_ROOT is not a harvard-dehallucinator checkout: " ++ p)
        Nothing -> getCurrentDirectory >>= climb
  where
    climb d = do
        ok <- isRoot d
        if ok
            then return (Right d)
            else let up = takeDirectory d
                 in if up == d
                        then return (Left "could not locate the repo root: looked for \
                                          \engine/verify_register.sh and state/ from the \
                                          \working directory upward. Set HARVARD_ROOT.")
                        else climb up

stateFileOf, verifierOf :: FilePath -> FilePath
stateFileOf root = root </> "state" </> "state.txt"
verifierOf  root = root </> "engine" </> "verify_register.sh"

-- ------------------------------------------------------------ parsing ------
-- Total. The original used bare `read` and `error "Corrupted State File"`,
-- so any malformed field crashed the one component meant to be durable.

parseState :: String -> Either String State
parseState raw = case lines raw of
    (t : c : a : s : _) ->
        State <$> int "totalItems" t
              <*> int "completed"  c
              <*> int "attempts"   a
              <*> str s
    ls -> Left ("state file malformed: expected 4 lines, found " ++ show (length ls))
  where
    int lbl v = maybe (Left (lbl ++ ": not an integer: " ++ show v)) Right
                      (readMaybe (trim v))
    str v = let v' = trim v
            in if null v' then Left "status: empty" else Right v'

readState :: FilePath -> IO (Either String State)
readState root = do
    let f = stateFileOf root
    ok <- doesFileExist f
    if not ok
        then return (Left ("no state file at " ++ f ++ " - run `init` or `init-from` first"))
        else do
            raw <- readFile f
            length raw `seq` return (parseState raw)  -- force before we rewrite

-- Atomic, and newline-safe: a newline in `status` used to corrupt the file
-- permanently, since the 4-line layout is positional.
writeState :: FilePath -> State -> IO ()
writeState root s = do
    let f     = stateFileOf root
        tmp   = f ++ ".tmp"
        flat  = map (\c -> if c == '\n' || c == '\r' then ' ' else c) (status s)
    writeFile tmp (unlines [ show (totalItems s), show (completed s)
                           , show (attempts s), flat ])
    renameFile tmp f

-- ----------------------------------------------------------- verifier ------
-- The sole source of truth about progress.

runVerifier :: FilePath -> FilePath -> IO (Either String Int)
runVerifier root target = do
    okT <- doesDirectoryExist target
    okV <- doesFileExist (verifierOf root)
    if not okT then return (Left ("target directory does not exist: " ++ target))
    else if not okV then return (Left ("verifier missing: " ++ verifierOf root))
    else do
        r <- try (readProcessWithExitCode "bash" [verifierOf root, target] "")
        return $ case r of
            Left e -> Left ("verifier failed to run: " ++ show (e :: SomeException))
            Right (ExitSuccess, out, _) ->
                maybe (Left ("verifier did not print an integer: " ++ show out))
                      Right (readMaybe (trim out))
            Right (code, _, err) ->
                Left ("verifier exited " ++ show code ++ ": " ++ trim err)

-- ----------------------------------------------------------- commands ------

die :: String -> IO a
die msg = hPutStrLn stderr ("ERROR: " ++ msg) >> exitWith (ExitFailure 1)

withState :: FilePath -> (State -> IO a) -> IO a
withState root k = readState root >>= either die k

-- Trips the breaker if the incremented count exceeds budget. Returns the
-- state to carry forward, or exits.
bumpOrTrip :: FilePath -> State -> IO State
bumpOrTrip root st0 = do
    let st1 = st0 { attempts = attempts st0 + 1 }
    if attempts st1 > totalItems st1 + attemptSlack
        then do
            writeState root st1 { status = statusStop }
            putStrLn "CIRCUIT BREAKER TRIGGERED: attempt budget exhausted. \
                     \Manual intervention required."
            exitWith (ExitFailure 3)
        else return st1

refuseIfStopped :: State -> IO ()
refuseIfStopped st
    | status st == statusStop =
        die "state is EMERGENCY_STOP. Reset deliberately before continuing."
    | otherwise = return ()

initExplicit :: FilePath -> Int -> IO ()
initExplicit root total = do
    writeState root (State total 0 0 statusRunning)
    putStrLn $ "Initialised Harvard Engine state with " ++ show total ++ " items."

initMeasured :: FilePath -> FilePath -> IO ()
initMeasured root target = runVerifier root target >>= \r -> case r of
    Left e  -> die ("cannot set a baseline without a measurement: " ++ e)
    Right n -> do
        writeState root (State n 0 0 statusRunning)
        putStrLn $ "Initialised baseline by MEASURING " ++ target ++ ": " ++ show n ++ " items."

bumpAttempt :: FilePath -> IO ()
bumpAttempt root = withState root $ \st0 -> do
    refuseIfStopped st0
    st1 <- bumpOrTrip root st0
    writeState root st1
    putStrLn $ "Attempt " ++ show (attempts st1) ++ "/"
             ++ show (totalItems st1 + attemptSlack) ++ " recorded."

-- The only function that can write COMPLETE, and only from a number this
-- process obtained from the verifier itself.
updateFromVerifier :: FilePath -> FilePath -> IO ()
updateFromVerifier root target = withState root $ \st0 -> do
    refuseIfStopped st0
    st1 <- bumpOrTrip root st0          -- every update costs an attempt
    r <- runVerifier root target
    case r of
        Left e -> do
            writeState root st1          -- attempt still counted
            hPutStrLn stderr ("VERIFICATION FAILED: " ++ e)
            hPutStrLn stderr "status unchanged. COMPLETE is unreachable without a count."
            exitWith (ExitFailure 4)
        Right remaining -> do
            let done = max 0 (totalItems st1 - remaining)
                st2  = st1 { completed = done
                           , status = if remaining == 0 then statusComplete else statusRunning }
            writeState root st2
            putStrLn $ "Verified " ++ target
            putStrLn $ "  remaining (measured): " ++ show remaining
            putStrLn $ "  progress: " ++ show done ++ "/" ++ show (totalItems st2)
            putStrLn $ "  status:   " ++ status st2

verifyOnly :: FilePath -> FilePath -> IO ()
verifyOnly root target = runVerifier root target >>= either die (putStrLn . show)

showStatus :: FilePath -> IO ()
showStatus root = withState root $ \st -> putStrLn $
    status st ++ "  " ++ show (completed st) ++ "/" ++ show (totalItems st)
    ++ " (attempts " ++ show (attempts st) ++ ")"

usage :: IO a
usage = do
    mapM_ (hPutStrLn stderr)
        [ "Usage: Engine <command>"
        , "  init <total>           set the baseline explicitly"
        , "  init-from <targetdir>  set the baseline by MEASURING the target"
        , "  attempt                record an attempt (arms the circuit breaker)"
        , "  update <targetdir>     re-measure and record progress"
        , "  verify <targetdir>     print the measured count; no state change"
        , "  status                 print current state"
        , ""
        , "`update <remaining>` from the original engine has been REMOVED."
        , "Progress cannot be asserted by a caller; it is only ever derived"
        , "from engine/verify_register.sh."
        ]
    exitWith (ExitFailure 2)

main :: IO ()
main = do
    args <- getArgs
    findRoot >>= either die (`dispatch` args)
  where
    dispatch root args = case args of
        ["init", n]           -> case readMaybe n of
            Just t | t >= 0   -> initExplicit root t
            _                 -> die ("init expects a non-negative integer, got " ++ show n)
        ["init-from", target] -> initMeasured root target
        ["attempt"]           -> bumpAttempt root
        ["update", target]    -> updateFromVerifier root target
        ["verify", target]    -> verifyOnly root target
        ["status"]            -> showStatus root
        _                     -> usage
