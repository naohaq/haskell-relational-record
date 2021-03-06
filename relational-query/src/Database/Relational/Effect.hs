-- |
-- Module      : Database.Relational.Effect
-- Copyright   : 2013-2017 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
--
-- This module defines effect statements
-- like update and delete.
module Database.Relational.Effect (
  -- * Object to express simple restriction.
  Restriction, restriction, restriction',

  -- * Object to express update target columns and restriction.
  UpdateTarget, updateTarget, updateTarget',
  liftTargetAllColumn, liftTargetAllColumn',
  updateTargetAllColumn, updateTargetAllColumn',

  -- * Object to express insert terget.
  InsertTarget, insertTarget, insertTarget', piRegister,

  -- * Generate SQL from restriction.
  sqlWhereFromRestriction,
  sqlFromUpdateTarget,
  sqlChunkFromInsertTarget,
  sqlFromInsertTarget,
  ) where

import Data.Monoid ((<>))
import Data.Functor.ProductIsomorphic (peRight)

import Language.SQL.Keyword (Keyword(..))
import Database.Record.Persistable (PersistableWidth)

import Database.Relational.Internal.Config (Config (chunksInsertSize), defaultConfig)
import Database.Relational.Internal.String (StringSQL, stringSQL, showStringSQL)
import Database.Relational.SqlSyntax
  (composeWhere, composeSets, composeChunkValuesWithColumns)

import Database.Relational.Pi (Pi, id')
import qualified Database.Relational.Pi.Unsafe as Pi
import Database.Relational.Table (Table, TableDerivable, derivedTable)
import qualified Database.Relational.Table as Table
import qualified Database.Relational.Record as Record
import Database.Relational.Projectable
  (PlaceHolders, unitPlaceHolder,
   pwPlaceholder, placeholder, (><), )
import Database.Relational.Monad.Trans.Assigning (assignings, (<-#))
import Database.Relational.Monad.Restrict (RestrictedStatement)
import qualified Database.Relational.Monad.Restrict as Restrict
import Database.Relational.Monad.Assign (AssignStatement)
import qualified Database.Relational.Monad.Assign as Assign
import Database.Relational.Monad.Register (Register)
import qualified Database.Relational.Monad.Register as Register


-- | Restriction type with place-holder parameter 'p' and projected record type 'r'.
newtype Restriction p r = Restriction (RestrictedStatement r (PlaceHolders p))

-- | Finalize 'Restrict' monad and generate 'Restriction'.
restriction :: RestrictedStatement r () -> Restriction () r
restriction = Restriction . ((>> return unitPlaceHolder) .)

-- | Finalize 'Restrict' monad and generate 'Restriction' with place-holder parameter 'p'
restriction' :: RestrictedStatement r (PlaceHolders p) -> Restriction p r
restriction' = Restriction

runRestriction :: Restriction p r
               -> RestrictedStatement r (PlaceHolders p)
runRestriction (Restriction qf) = qf

-- | SQL WHERE clause 'StringSQL' string from 'Restriction'.
sqlWhereFromRestriction :: Config -> Table r -> Restriction p r -> StringSQL
sqlWhereFromRestriction config tbl (Restriction q) = composeWhere rs
  where (_ph, rs) = Restrict.extract (q $ Record.unsafeFromTable tbl) config

-- | Show where clause.
instance TableDerivable r => Show (Restriction p r) where
  show = showStringSQL . sqlWhereFromRestriction defaultConfig derivedTable


-- | UpdateTarget type with place-holder parameter 'p' and projected record type 'r'.
newtype UpdateTarget p r = UpdateTarget (AssignStatement r (PlaceHolders p))

-- | Finalize 'Target' monad and generate 'UpdateTarget'.
updateTarget :: AssignStatement r ()
             -> UpdateTarget () r
updateTarget =  UpdateTarget . ((>> return unitPlaceHolder) .)

-- | Finalize 'Target' monad and generate 'UpdateTarget' with place-holder parameter 'p'.
updateTarget' :: AssignStatement r (PlaceHolders p)
              -> UpdateTarget p r
updateTarget' = UpdateTarget

updateAllColumn :: PersistableWidth r
                => Restriction p r
                -> AssignStatement r (PlaceHolders (r, p))
updateAllColumn rs proj = do
  (ph0, ()) <- placeholder (\ph -> id' <-# ph)
  ph1       <- assignings $ runRestriction rs proj
  return $ ph0 >< ph1

-- | Lift 'Restriction' to 'UpdateTarget'. Update target columns are all.
liftTargetAllColumn :: PersistableWidth r
                     => Restriction () r
                     -> UpdateTarget r r
liftTargetAllColumn rs = updateTarget' $ \proj -> fmap peRight $ updateAllColumn rs proj

-- | Lift 'Restriction' to 'UpdateTarget'. Update target columns are all. With placefolder type 'p'.
liftTargetAllColumn' :: PersistableWidth r
                     => Restriction p r
                     -> UpdateTarget (r, p) r
liftTargetAllColumn' rs = updateTarget' $ updateAllColumn rs

-- | Finalize 'Restrict' monad and generate 'UpdateTarget'. Update target columns are all.
updateTargetAllColumn :: PersistableWidth r
                      => RestrictedStatement r ()
                      -> UpdateTarget r r
updateTargetAllColumn = liftTargetAllColumn . restriction

-- | Finalize 'Restrict' monad and generate 'UpdateTarget'. Update target columns are all. With placefolder type 'p'.
updateTargetAllColumn' :: PersistableWidth r
                       => RestrictedStatement r (PlaceHolders p)
                       -> UpdateTarget (r, p) r
updateTargetAllColumn' = liftTargetAllColumn' . restriction'


-- | SQL SET clause and WHERE clause 'StringSQL' string from 'UpdateTarget'
sqlFromUpdateTarget :: Config -> Table r -> UpdateTarget p r -> StringSQL
sqlFromUpdateTarget config tbl (UpdateTarget q) = composeSets (asR tbl) <> composeWhere rs
  where ((_ph, asR), rs) = Assign.extract (q (Record.unsafeFromTable tbl)) config

instance TableDerivable r => Show (UpdateTarget p r) where
  show = showStringSQL . sqlFromUpdateTarget defaultConfig derivedTable


-- | InsertTarget type with place-holder parameter 'p' and projected record type 'r'.
newtype InsertTarget p r = InsertTarget (Register r (PlaceHolders p))

-- | Finalize 'Register' monad and generate 'InsertTarget'.
insertTarget :: Register r ()
             -> InsertTarget () r
insertTarget =  InsertTarget . (>> return unitPlaceHolder)

-- | Finalize 'Target' monad and generate 'UpdateTarget' with place-holder parameter 'p'.
insertTarget' :: Register r (PlaceHolders p)
              -> InsertTarget p r
insertTarget' = InsertTarget

-- | parametalized 'Register' monad from 'Pi'
piRegister :: PersistableWidth r
           => Pi r r'
           -> Register r (PlaceHolders r')
piRegister pi' = do
  let (ph', ma) = pwPlaceholder (Pi.width' pi') (\ph -> pi' <-# ph)
  () <- ma
  return ph'

sqlChunkFromInsertTarget' :: Config
                          -> Int
                          -> Table r
                          -> InsertTarget p r
                          -> StringSQL
sqlChunkFromInsertTarget' config sz tbl (InsertTarget q) =
    INSERT <> INTO <> stringSQL (Table.name tbl) <> composeChunkValuesWithColumns sz (asR tbl)
  where
    (_ph, asR) = Register.extract q config

-- | Make 'StringSQL' string of SQL INSERT record chunk statement from 'InsertTarget'
sqlChunkFromInsertTarget :: Config
                         -> Table r
                         -> InsertTarget p r
                         -> (StringSQL, Int)
sqlChunkFromInsertTarget config tbl it =
    (sqlChunkFromInsertTarget' config n tbl it, n)
  where
    th = chunksInsertSize config
    n  = (th + w - 1) `quot` w
    w  = Table.width tbl

-- | Make 'StringSQL' string of SQL INSERT statement from 'InsertTarget'
sqlFromInsertTarget :: Config -> Table r -> InsertTarget p r -> StringSQL
sqlFromInsertTarget config = sqlChunkFromInsertTarget' config 1
