-include .env

# Install dependencies
install :;
	@forge install foundry-rs/forge-std@master --no-commit && \
	npm install

update :;
	@forge update

# Run tests
tests :;
	@forge test -vvv

# Coverage
coverage :;
	@forge coverage

# Coverage report
coverage-report :;
	@forge coverage --report lcov