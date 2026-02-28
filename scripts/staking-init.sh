aptos init --profile local-operator \
  --network local

aptos init --profile local-voter \
  --network local

aptos stake create-staking-contract \
--operator 9ef9b51760561cac89a7e2ecedf1ba3ffc3f1f2b77d0971c81ebf42b5c499f9f \
--voter e742dcf3c51b356859304db82b9d338d8134902f6508e7142481123e7c0fb091 \
--amount 100000000000000 \
--commission-percentage 10 \
--profile default

aptos node get-stake-pool \
  --owner-address e742dcf3c51b356859304db82b9d338d8134902f6508e7142481123e7c0fb091 \
  --profile local-operator