{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE Rank2Types                #-}
module Control.Concurrent.NQE.Supervisor
    ( Supervisor
    , Child
    , ChildAction
    , ChildStopped
    , SupervisorMessage
    , Strategy(..)
    , supervisor
    , addChild
    , removeChild
    , stopSupervisor
    ) where

import           Control.Applicative
import           Control.Concurrent.NQE.Process
import           Control.Monad
import           Control.Monad.STM              (catchSTM)
import           UnliftIO

type Supervisor = Inbox SupervisorMessage
type Child = Async ()
type ChildAction = IO ()
type ChildStopped = (Child, Either SomeException ())

-- | A supervisor will start, stop and monitor processes.
data SupervisorMessage
    = AddChild ChildAction
               (Reply Child)
    | RemoveChild Child
    | StopSupervisor

-- | Supervisor strategies to decide what to do when a child stops.
data Strategy
    = Notify (Listen ChildStopped)
    -- ^ run this 'STM' action when a process stops
    | KillAll
    -- ^ kill all processes and propagate exception
    | IgnoreGraceful
    -- ^ ignore processes that stop without raising exceptions
    | IgnoreAll
    -- ^ do nothing and keep running if a process dies

-- | Run a supervisor with a given 'Strategy' a 'Mailbox' to control it, and a
-- list of children to launch. The list can be empty.
supervisor :: Strategy -> Supervisor -> [ChildAction] -> IO ()
supervisor strat mbox children = do
    state <- newTVarIO []
    finally (go state) (down state)
  where
    go state = do
        mapM_ (startChild state) children
        loop state
    loop state = do
        e <-
            atomically $
            Right <$> receiveSTM mbox <|> Left <$> waitForChild state
        again <-
            case e of
                Right m -> processMessage state m
                Left x  -> processDead state strat x
        when again $ loop state
    down state = do
        as <- readTVarIO state
        mapM_ cancel as

-- | Internal action to wait for a child process to finish running.
waitForChild :: TVar [Async ()] -> STM (Async (), Either SomeException ())
waitForChild state = do
    as <- readTVar state
    waitAnyCatchSTM as

processMessage :: TVar [Child] -> SupervisorMessage -> IO Bool
processMessage state (AddChild ch r) = do
    a <- async ch
    atomically $ do
        modifyTVar' state (a:)
        r a
    return True

processMessage state (RemoveChild a) = do
    atomically (modifyTVar' state (filter (/= a)))
    cancel a
    return True

processMessage state StopSupervisor = do
    as <- readTVarIO state
    forM_ as (stopChild state)
    return False

processDead :: TVar [Child] -> Strategy -> ChildStopped -> IO Bool
processDead state IgnoreAll (a, _) = do
    atomically (modifyTVar' state (filter (/= a)))
    return True

processDead state KillAll (a, e) = do
    as <- atomically $ do
        modifyTVar' state (filter (/= a))
        readTVar state
    mapM_ (stopChild state) as
    case e of
        Left x   -> throwIO x
        Right () -> return False

processDead state IgnoreGraceful (a, Right ()) = do
    atomically (modifyTVar' state (filter (/= a)))
    return True

processDead state IgnoreGraceful (a, Left e) = do
    as <- atomically $ do
        modifyTVar' state (filter (/= a))
        readTVar state
    mapM_ (stopChild state) as
    throwIO e

processDead state (Notify notif) (a, e) = do
    x <-
        atomically $ do
            modifyTVar' state (filter (/= a))
            catchSTM (notif (a, e) >> return Nothing) $ \x ->
                return $ Just (x :: SomeException)
    case x of
        Nothing -> return True
        Just ex -> do
            as <- readTVarIO state
            forM_ as (stopChild state)
            throwIO ex

-- | Internal function to start a child process.
startChild :: TVar [Child] -> ChildAction -> IO (Async ())
startChild state run = do
    a <- liftIO $ async run
    atomically (modifyTVar' state (a:))
    return a

-- | Internal fuction to stop a child process.
stopChild :: TVar [Child] -> Child -> IO ()
stopChild state a = do
    isChild <-
        atomically $ do
            cur <- readTVar state
            let new = filter (/= a) cur
            writeTVar state new
            return (cur /= new)
    when isChild (cancel a)

-- | Add a new child process to the supervisor. The child process will run in
-- the supervisor context. Will return an 'Async' for the child. This function
-- will not block or raise an exception if the child dies.
addChild :: MonadIO m => Supervisor -> ChildAction -> m Child
addChild mbox action = AddChild action `query` mbox

-- | Stop a child process controlled by the supervisor. Must pass the child
-- 'Async'. Will not wait for the child to die.
removeChild :: MonadIO m => Supervisor -> Child -> m ()
removeChild mbox child = RemoveChild child `send` mbox

-- | Stop the supervisor and its children.
stopSupervisor :: MonadIO m => Supervisor -> m ()
stopSupervisor mbox = StopSupervisor `send` mbox
