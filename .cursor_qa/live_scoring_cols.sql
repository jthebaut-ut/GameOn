SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'pickup_games'
  AND column_name IN (
    'team_score','opponent_score','scoring_status','scoring_finalized_at','home_score','away_score'
  )
ORDER BY 1;
