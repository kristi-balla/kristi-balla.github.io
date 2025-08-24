FROM ruby:3.2-slim-bookworm

RUN apt-get update -qq && apt-get install -y \
    build-essential \
    git \
    libffi-dev \
    libxml2-dev \
    libxslt1-dev \
    zlib1g-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

# Install bundler (match your lockfile version if needed)
RUN gem install bundler -v 2.6.1

# Copy Gemfiles first (for caching)
COPY Gemfile ./

# Install Ruby gems
RUN bundle install
COPY . .

# why? Bc fuck ruby, that's why!
RUN bundle install
EXPOSE 4000

# Default command: serve site
CMD ["bundle", "exec", "jekyll", "serve", "--host", "0.0.0.0"]
