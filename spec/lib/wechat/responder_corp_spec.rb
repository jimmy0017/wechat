require 'spec_helper'

include Wechat::Cipher

ENCODING_AES_KEY = Base64.encode64 SecureRandom.hex(16)

class WechatCorpController < ApplicationController
  wechat_responder corpid: 'corpid', corpsecret: 'corpsecret', token: 'token', access_token: 'controller_access_token',
                   agentid: 1, encoding_aes_key: ENCODING_AES_KEY
end

RSpec.describe WechatCorpController, type: :controller do
  render_views

  let(:message_base) do
    {
      ToUserName: 'toUser',
      FromUserName: 'fromUser',
      CreateTime: '1348831860',
      MsgId: '1234567890123456'
    }
  end

  def signature_params(msg = {})
    xml = message_base.merge(msg).to_xml(root: :xml, skip_instruct: true)

    encrypt = Base64.strict_encode64 encrypt(pack(xml, 'appid'), ENCODING_AES_KEY)
    xml = { Encrypt: encrypt }
    timestamp = '1234567'
    nonce = 'nonce'
    msg_signature = Digest::SHA1.hexdigest(['token', timestamp, nonce, xml[:Encrypt]].sort.join)
    { timestamp: timestamp, nonce: nonce, xml: xml, msg_signature: msg_signature }
  end

  def signature_echostr(echostr)
    encrypt_echostr = Base64.strict_encode64 encrypt(pack(echostr, 'appid'), ENCODING_AES_KEY)
    timestamp = '1234567'
    nonce = 'nonce'
    msg_signature = Digest::SHA1.hexdigest(['token', timestamp, nonce, encrypt_echostr].sort.join)
    { timestamp: timestamp, nonce: nonce, echostr: encrypt_echostr, msg_signature: msg_signature }
  end

  def xml_to_hash(response)
    Hash.from_xml(response.body)['xml'].symbolize_keys
  end

  describe 'Verify signature' do
    it 'on create action faild' do
      post :create, signature_params.merge(msg_signature: 'invalid')
      expect(response.code).to eq '403'
    end

    it 'on create action success' do
      post :create, signature_params(MsgType: 'voice', Voice: { MediaId: 'mediaID' })
      expect(response.code).to eq '200'
      expect(response.body.length).to eq 0
    end
  end

  specify "echo 'echostr' param when show" do
    get :show, signature_echostr('hello')
    expect(response.body).to eq('hello')
  end

  describe 'corp' do
    controller do
      wechat_responder corpid: 'corpid', corpsecret: 'corpsecret', token: 'token', access_token: 'controller_access_token',
                       agentid: 1, encoding_aes_key: ENCODING_AES_KEY

      on :text do |request, content|
        request.reply.text "echo: #{content}"
      end

      on :event, with: 'subscribe' do |request|
        request.reply.text 'welcome!'
      end

      on :event, with: 'my_event' do |request, _key|
        request.reply.text 'echo: my_event'
      end

      on :event, with: 'BINDING_QR_CODE' do |request, scan_type, scan_result|
        request.reply.text "User #{request[:FromUserName]} ScanType #{scan_type} ScanResult #{scan_result}"
      end
    end

    specify 'will set controller wechat api and token' do
      access_token = controller.class.wechat.access_token
      expect(access_token.token_file).to eq 'controller_access_token'
      expect(controller.class.token).to eq 'token'
      expect(controller.class.agentid).to eq 1
      expect(controller.class.encrypt_mode).to eq true
      expect(controller.class.encoding_aes_key).to eq ENCODING_AES_KEY
    end

    describe 'response' do
      it 'Verify response signature' do
        post :create, signature_params(MsgType: 'text', Content: 'hello')
        expect(response.code).to eq '200'
        expect(response.body.empty?).to eq false

        data = Hash.from_xml(response.body)['xml']

        msg_signature = Digest::SHA1.hexdigest [data['TimeStamp'], data['Nonce'], 'token', data['Encrypt']].sort.join
        expect(data['MsgSignature']).to eq msg_signature
      end

      it 'on text' do
        post :create, signature_params(MsgType: 'text', Content: 'hello')
        expect(response.code).to eq '200'
        expect(response.body.empty?).to eq false

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'echo: hello'
      end

      it 'on subscribe' do
        post :create, signature_params(MsgType: 'event', Event: 'subscribe')
        expect(response.code).to eq '200'

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'welcome!'
      end

      it 'on event' do
        post :create, signature_params(MsgType: 'event', Event: 'click', EventKey: 'my_event')
        expect(response.code).to eq '200'

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'echo: my_event'
      end

      it 'on BINDING_QR_CODE' do
        post :create, signature_params(FromUserName: 'userid', MsgType: 'event', Event: 'scancode_push', EventKey: 'BINDING_QR_CODE',
                                       ScanCodeInfo: { ScanType: 'qrcode', ScanResult: 'scan_result' })
        expect(response.code).to eq '200'

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'User userid ScanType qrcode ScanResult scan_result'
      end
    end
  end
end
