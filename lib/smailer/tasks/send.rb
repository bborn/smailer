require 'mail'

module Smailer
  module Tasks
    class Send
      def self.execute(options = {})
        options.reverse_merge! :verp => !options[:return_path_domain].blank?

        # validate options
        if options[:verp] && options[:return_path_domain].blank?
          raise "VERP is enabled, but a :return_path_domain option has not been specified or is blank."
        end

        rails_delivery_method = if Smailer::Compatibility.rails_3_or_4?
          method = Rails.configuration.action_mailer.delivery_method
          [ActionMailer::Base.delivery_methods[method], ActionMailer::Base.send("#{method}_settings")]
        else
          [ActionMailer::Base.delivery_method]
        end

        Mail.defaults do
          delivery_method *rails_delivery_method
        end

        batch_size   = (Smailer::Models::Property.get('queue.batch_size') || 100).to_i
        max_retries  = (Smailer::Models::Property.get('queue.max_retries') || 0).to_i
        max_lifetime = (Smailer::Models::Property.get('queue.max_lifetime') || 172800).to_i

        results = []

        # clean up any old locked items
        expired_locks_condition = ['locked = ? AND locked_at <= ?', true, 1.hour.ago.utc]
        if Smailer::Compatibility.rails_3_or_4?
          Smailer::Models::QueuedMail.where(expired_locks_condition).update_all(:locked => false)
        else
          Smailer::Models::QueuedMail.update_all({:locked => false}, expired_locks_condition)
        end

        # load the queue items to process
        queue_sort_order = 'retries ASC, id ASC'
        items_to_process = if Smailer::Compatibility.rails_3_or_4?
          Smailer::Models::QueuedMail.where(:locked => false).order(queue_sort_order).limit(batch_size)
        else
          Smailer::Models::QueuedMail.all(:conditions => {:locked => false}, :order => queue_sort_order, :limit => batch_size)
        end

        # lock the queue items
        lock_condition = {:id => items_to_process.map(&:id)}
        lock_update = {:locked => true, :locked_at => Time.now.utc}
        if Smailer::Compatibility.rails_3_or_4?
          Smailer::Models::QueuedMail.where(lock_condition).update_all(lock_update)
        else
          Smailer::Models::QueuedMail.update_all(lock_update, lock_condition)
        end

        # map of attachment ID to contents - so we don't keep opening files
        # or URLs
        cached_attachments = {}

        items_to_process.each do |queue_item|
          # try to send the email
          mail = Mail.new do
            from    queue_item.from
            to      queue_item.to
            subject queue_item.subject
            queue_item.mail_campaign.attachments.each do |attachment|
              cached_attachments[attachment.id] ||= attachment.body
              add_file :filename => attachment.filename,
                       :content => cached_attachments[attachment.id]
            end

            text_part { body queue_item.body_text }
            html_part { body queue_item.body_html; content_type 'text/html; charset=UTF-8' }
          end
          mail.raise_delivery_errors = true

          # compute the VERP'd return_path if requested
          # or fall-back to a global return-path if not
          item_return_path = if options[:verp]
             "#{Smailer::BOUNCES_PREFIX}#{queue_item.key}@#{options[:return_path_domain]}"
          else
            options[:return_path]
          end

          # set the return-path, if any
          if item_return_path
            mail.return_path   = item_return_path
            mail['Errors-To']  = item_return_path
            mail['Bounces-To'] = item_return_path
          end

          queue_item.last_retry_at = Time.now
          queue_item.retries      += 1
          queue_item.locked        = false # unlock this email

          begin
            # commense delivery
            mail.deliver
          rescue Exception => e
            # failed, we have.
            queue_item.last_error = "#{e.class.name}: #{e.message}"
            queue_item.save

            # check if the message hasn't expired;
            retries_exceeded = max_retries  > 0 && queue_item.retries >= max_retries
            too_old = max_lifetime > 0 && (Time.now - queue_item.created_at) >= max_lifetime

            if retries_exceeded || too_old
              # the message has expired; move to finished_mails
              Smailer::Models::FinishedMail.add(queue_item, Smailer::Models::FinishedMail::Statuses::FAILED)
            end
            results.push [queue_item, :failed]
          else
            # great job, message sent
            Smailer::Models::FinishedMail.add(queue_item, Smailer::Models::FinishedMail::Statuses::SENT)
            results.push [queue_item, :sent]
          end
        end

        results
      end
    end
  end
end
