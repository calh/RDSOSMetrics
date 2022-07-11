FROM lambci/lambda:build-ruby2.7

RUN gem update bundler

WORKDIR /usr/src/app
COPY Gemfile /usr/src/app
RUN bundle config --local silence_root_warning true
RUN bundle config set --local clean 'true'
RUN bundle config set --local path 'vendor/bundle'
RUN bundle install 

COPY . /usr/src/app

# Remove AWS SDK gems, since they're already included in the base Lambda image.
# It saves a lot of space on the deployment package
RUN zip -r deploy.zip * \
  -x Dockerfile \
  -x aws_runner.rb \
  -x script/\* \
  -x vendor/bundle/ruby/2.7.0/cache/\* \
  -x vendor/bundle/ruby/\*/\*/aws-\* \
  -x vendor/bundle/ruby/\*/cache \
  -x vendor/bundle/ruby/\*/\*/jmespath*

CMD "/bin/bash"

