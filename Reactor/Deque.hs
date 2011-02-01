{-# LANGUAGE UndecidableInstances, FlexibleContexts, DeriveDataTypeable #-}

module Reactor.Deque (
    Deque 

  -- * Local stack operations
  , empty        -- :: (MonadIO m, MArray a e IO) => IO (Deque a e)
  , push         -- :: (MonadIO m, MArray a e IO) => e -> Deque a e -> IO ()
  , pop          -- :: (MonadIO m, MArray a e IO) => Deque a e -> IO (Maybe e)

  -- * Performance tuning
  , withCapacity -- :: (MonadIO m, MArray a e IO) => Int -> IO (Deque a e)
  , minimumCapacity -- :: Int
  , defaultCapacity -- :: Int

  -- * Work stealing
  , steal        -- :: (MonadIO m, MArray a e IO) => Deque a e -> IO (Stolen e)
  , Stolen(..)  
  ) where

-- | For an explanation of the implementation, see \"Dynamic Circular Work-Stealing Deque\" 
-- by David Chase and Yossi Lev of Sun Microsystems.

import Prelude hiding (read)
import Control.Applicative hiding (empty)
import Data.Bits.Atomic
import Foreign.Ptr
import Foreign.ForeignPtr
import Foreign.Storable
import Data.IORef
import Data.Array.MArray
import Control.Monad
import Control.Monad.IO.Class
import Data.Data
import System.IO.Unsafe

data Buffer a e = Buffer {-# UNPACK #-} !Int !(a Int e) 

instance Typeable2 a => Typeable1 (Buffer a) where
  typeOf1 tae = mkTyConApp bufferTyCon [typeOf1 (aInte tae)]
    where aInte :: t a e -> a Int e
          aInte = undefined

bufferTyCon :: TyCon
bufferTyCon = mkTyCon "Reactor.Deque.Buffer"

size :: Buffer a e -> Int
size (Buffer i _) = i

data Deque a e = Deque 
  { _tb :: ForeignPtr Int 
  , _content :: IORef (Buffer a e)
  }

instance (MArray a e IO, Show e) => Show (Deque a e) where
  showsPrec d (Deque tb content) = unsafePerformIO $ do
    (t,b) <- withForeignPtr tb $ \p -> (,) <$> peekTop p <*> peekBottom p 
    buffer <- readIORef content
    contents <- forM [t..b-1] (read buffer)
    return $ showParen (d > 10) $ 
      showString "Deque (ptr " . showsPrec 11 t . showChar ' ' . showsPrec 11 b . showString ") (buffer " . showsPrec 11 contents . showChar ')'

instance Typeable2 a => Typeable1 (Deque a) where
  typeOf1 dae = mkTyConApp dequeTyCon [typeOf1 (aInte dae)]
    where aInte :: t a e -> a Int e
          aInte = undefined

dequeTyCon :: TyCon
dequeTyCon = mkTyCon "Reactor.Deque.Deque"

ptr :: Storable a => a -> a -> IO (ForeignPtr a)
ptr a b = do
  p <- mallocForeignPtrArray 2
  withForeignPtr p $ \q -> do 
    poke q a
    pokeElemOff q 1 b
  return p

minimumCapacity :: Int
minimumCapacity = 16

defaultCapacity :: Int
defaultCapacity = 32

bufferWithCapacity :: MArray a e IO => Int -> IO (Buffer a e)
bufferWithCapacity i = 
  Buffer i <$> newArray_ (0, (minimumCapacity `max` i) - 1)

withCapacity :: (MonadIO m, MArray a e IO) => Int -> m (Deque a e)
withCapacity i = liftIO (Deque <$> ptr 0 0 <*> (bufferWithCapacity i >>= newIORef))

empty :: (MonadIO m, MArray a e IO) => m (Deque a e)
empty = withCapacity defaultCapacity
{-# INLINE empty #-}
  
-- unsafeRead 
read :: MArray a e IO => Buffer a e -> Int -> IO e
read (Buffer s c) i = do
  readArray c (i `mod` s)
{-# INLINE read #-}

-- unsafeWrite
write :: MArray a e IO => Buffer a e -> Int -> e -> IO ()
write (Buffer s c) i e = do
  writeArray c (i `mod` s) e
{-# INLINE write #-}

grow :: MArray a e IO => Buffer a e -> Int -> Int -> IO (Buffer a e) 
grow c b t = do
  c' <- bufferWithCapacity (size c * 2)
  forM_ [t..b-1] $ \i -> read c i >>= write c' i 
  return c'
{-# INLINE grow #-}

peekBottom :: Ptr Int -> IO Int
peekBottom p = peekElemOff p 1

peekTop :: Ptr Int -> IO Int
peekTop p = peek p

pokeBottom :: Ptr Int -> Int -> IO ()
pokeBottom p = pokeElemOff p 1

push  :: (MonadIO m, MArray a e IO) => e -> Deque a e -> m ()
push o (Deque tb content) = liftIO $ withForeignPtr tb $ \p -> do
  b <- peekBottom p
  t <- peekTop p
  a <- readIORef content
  let size' = b - t
  if size' >= size a
    then do 
      a' <- grow a b t 
      writeIORef content a' 
      go p a' b
    else go p a  b
  where
    go p arr b = do
      write arr b o
      pokeBottom p (b + 1)

data Stolen e 
  = Empty 
  | Abort 
  | Stolen e
  deriving (Data,Typeable,Eq,Ord,Show,Read)

steal :: (MonadIO m, MArray a e IO) => Deque a e -> m (Stolen e)
steal (Deque tb content) = liftIO $ withForeignPtr tb $ \p -> do 
     t <- peekTop p
     b <- peekBottom p
     a <- readIORef content
     let size' = b - t
     if size' <= 0
       then return Empty
       else do
         o <- read a t
         result <- compareAndSwapBool p t (t + 1)
         return $ if result then Stolen o else Abort

{-
steal' :: MArray a e IO => Deque a e -> IO (Maybe e)
steal' deque = do
  s <- steal deque 
  case s of
    Stolen e -> return (Just e)
    Empty -> return Nothing
    Abort -> steal' deque
-}

pop :: (MonadIO m, MArray a e IO) => Deque a e -> m (Maybe e)
pop (Deque tb content) = liftIO $ withForeignPtr tb $ \p -> do
  b <- peekBottom p
  a <- readIORef content
  let b' = b - 1
  pokeBottom p b'
  t <- peekTop p
  let size' = b' - t
  if size' < 0 
    then do
      pokeBottom p t
      return Nothing
    else do
      o <- read a b'
      if size' > 0 
        then return (Just o)
        else do
          result <- compareAndSwapBool p t (t + 1)
          if result 
            then do
              pokeBottom p (t + 1)
              return (Just o)
            else do
              pokeBottom p (t + 1)
              return Nothing
