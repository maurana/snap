{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Snap.Loader.Hint where

------------------------------------------------------------------------------
import qualified Data.ByteString.Char8 as S

import           Data.List (groupBy, intercalate, isPrefixOf, nub)

import           Control.Concurrent (forkIO)
import           Control.Concurrent.MVar
import           Control.Monad (when)
import           Control.Monad.Trans (liftIO)

import           Data.Maybe (catMaybes)
import           Data.Time.Clock

import           Language.Haskell.Interpreter hiding (lift, liftIO)
import           Language.Haskell.Interpreter.Unsafe (unsafeSetGhcOption)

import           Language.Haskell.TH.Syntax

import           System.Environment (getArgs)

------------------------------------------------------------------------------
import           Snap.Error
import           Snap.Types
import qualified Snap.Loader.Static as Static

------------------------------------------------------------------------------
-- | XXX
-- Assumes being spliced into the same source tree as the action to
-- dynamically load is located in
loadSnapTH :: Name -> Name -> Name -> Q Exp
loadSnapTH initialize cleanup action = do
    args <- runIO getArgs

    let initMod = nameModule initialize
        initBase = nameBase initialize
        cleanMod = nameModule cleanup
        cleanBase = nameBase cleanup
        actMod = nameModule action
        actBase = nameBase action

        modules = catMaybes [initMod, cleanMod, actMod]
        opts = getHintOpts args

    hintSnapE <- [| \o m i c a ->
                      fmap ((,) $ return ()) $ hintSnap o m i c a |]

    [ optsE, modulesE ]     <- mapM lift [ opts, modules ]
    [ initE, cleanE, actE ] <- mapM lift [ initBase, cleanBase, actBase ]

    staticE <- Static.loadSnapTH initialize cleanup action

    -- Wrap the hintSnap call in a let block.  This let block
    -- vacuously pattern-matches the static expression, providing an
    -- extra check that the types were correct at compile-time, at
    -- least.  This check isn't infallible, because the type isn't
    -- fully specified, but it's an extra level of help with
    -- negligible compile-time cost.
    let hintApp = foldl AppE hintSnapE [optsE, modulesE, initE, cleanE, actE]
        nameUnused = mkName "_"
        body = NormalB staticE
        clause = Clause [] body []
        staticDec = FunD nameUnused [clause]

    return $ LetE [staticDec] hintApp


------------------------------------------------------------------------------
-- | XXX
getHintOpts :: [String] -> [String]
getHintOpts args = "-hide-package=mtl" : filter (not . (`elem` bad)) opts
  where
    bad = ["-threaded"]
    hideAll = filter (== "-hide-all-packages") args

    srcOpts = filter (\x -> "-i" `isPrefixOf` x
                            && not ("-idist" `isPrefixOf` x)) args

    toCopy = init $ dropWhile (/= "-package") args
    copy = map (intercalate " ") . groupBy (\_ s -> not $ "-" `isPrefixOf` s)

    opts = hideAll ++ srcOpts ++ copy toCopy


------------------------------------------------------------------------------
-- | XXX
hintSnap :: [String] -> [String] -> String -> String -> String -> IO (Snap ())
hintSnap opts mNames initBase cleanBase actBase = do
    let action = intercalate " " ["bracketSnap", initBase, cleanBase, actBase]
        interpreter = do
            mapM_ unsafeSetGhcOption opts
            loadModules . nub $ mNames
            let allMods = "Prelude" : "Snap.Types" : mNames
            setImports . nub $ allMods
            interpret action (as :: Snap ())

    loadAction <- protectedActionEvaluator 3 $ runInterpreter interpreter

    return $ do
        eSnap <- liftIO loadAction
        case eSnap of
            Left err -> internalError $ format err
            Right handler -> catch500 handler


------------------------------------------------------------------------------
-- | XXX
format :: InterpreterError -> S.ByteString
format (UnknownError e)   =
    S.append "Unknown interpreter error:\r\n\r\n" $ S.pack e

format (NotAllowed e)     =
    S.append "Interpreter action not allowed:\r\n\r\n" $ S.pack e

format (GhcException e)   =
    S.append "GHC error:\r\n\r\n" $ S.pack e

format (WontCompile errs) =
    let formatted = S.intercalate "\r\n" . map S.pack . nub . map errMsg $ errs
    in S.append "Compile errors:\r\n\r\n" formatted


------------------------------------------------------------------------------
-- | XXX
protectedActionEvaluator :: NominalDiffTime -> IO a -> IO (IO a)
protectedActionEvaluator minReEval action = do
    readerContainer <- newMVar []
    resultContainer <- newMVar Nothing
    return $ do
        existingResult <- readMVar resultContainer
        now <- getCurrentTime

        case existingResult of
            Just (val, ts) | diffUTCTime now ts < minReEval -> return val
            _ -> do
                reader <- newEmptyMVar
                readers <- takeMVar readerContainer

                when (null readers) $ do
                    forkIO $ do
                        result <- action
                        allReaders <- takeMVar readerContainer
                        finishTime <- getCurrentTime
                        swapMVar resultContainer $ Just (result, finishTime)
                        putMVar readerContainer []
                        mapM_ (flip putMVar result) allReaders
                    return ()

                putMVar readerContainer $ reader : readers
                takeMVar reader
