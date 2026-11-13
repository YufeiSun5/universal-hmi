package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"time"

	"connectrpc.com/connect"
	rt "github.com/YufeiSun5/universal-hmi/backend/internal/runtime"
	"github.com/YufeiSun5/universal-hmi/backend/internal/runtimewire"
	"github.com/YufeiSun5/universal-hmi/backend/internal/storage"
)

const runtimeSubscribeProcedure = runtimewire.SubscribeProcedure

// Standard binary gRPC-Web works over the existing HTTP/HTTPS listeners and
// Android's pinned mTLS adapter. Connect also accepts native gRPC over HTTP/2.
func runtimeGRPC(e *rt.Engine) http.Handler {
	slots := make(chan struct{}, maxDeltaStreams)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		controller := http.NewResponseController(w)
		defer controller.SetWriteDeadline(time.Time{})
		handler := connect.NewServerStreamHandler(runtimeSubscribeProcedure,
			func(ctx context.Context, request *connect.Request[runtimewire.SubscribeRequest], stream *connect.ServerStream[runtimewire.RuntimeFrame]) error {
				select {
				case slots <- struct{}{}:
					defer func() { <-slots }()
				default:
					return connect.NewError(connect.CodeResourceExhausted, errors.New("实时订阅已满"))
				}
				in := request.Msg
				if (in.AllAuthorized && (in.Overview || len(in.PointIds) != 0)) || (in.Overview && len(in.PointIds) != 0) || len(in.PointIds) > maxExplicitIDs {
					return connect.NewError(connect.CodeInvalidArgument, errors.New("invalid subscription"))
				}
				// Reuse the legacy selector validation and authorization-scoped overview.
				query := url.Values{}
				if in.Overview {
					query.Set("scope", "overview")
				} else if !in.AllAuthorized {
					for _, id := range in.PointIds {
						if strings.Contains(id, ",") {
							return connect.NewError(connect.CodeInvalidArgument, errors.New("invalid point ID"))
						}
					}
					query.Set("ids", strings.Join(in.PointIds, ","))
				}
				selected := r.Clone(ctx)
				selected.URL.RawQuery = query.Encode()
				ids, err := runtimeSubscriptionIDs(selected, e)
				if err != nil {
					return connect.NewError(connect.CodeInvalidArgument, errors.New("invalid subscription"))
				}
				stream.ResponseHeader().Set("Cache-Control", "no-store")
				stream.ResponseHeader().Set("X-Accel-Buffering", "no")
				err = serveRuntimeDelta(e, selected, ids, func(frame *runtimeDeltaFrame) error {
					message, err := protobufRuntimeFrame(frame)
					if err != nil {
						return err
					}
					_ = controller.SetWriteDeadline(time.Now().Add(5 * time.Second))
					return stream.Send(message)
				})
				if errors.Is(err, errRuntimeSessionExpired) {
					return connect.NewError(connect.CodeUnauthenticated, errors.New("登录状态已失效"))
				}
				if errors.Is(err, context.Canceled) {
					return connect.NewError(connect.CodeCanceled, err)
				}
				if err != nil {
					return connect.NewError(connect.CodeInternal, errors.New("实时通道中断"))
				}
				return nil
			}, connect.WithReadMaxBytes(1024*1024), connect.WithSendMaxBytes(32*1024*1024))
		handler.ServeHTTP(w, r)
	})
}

func protobufScalar(value any) (*runtimewire.Scalar, error) {
	out := &runtimewire.Scalar{}
	switch v := value.(type) {
	case nil:
		out.Kind = &runtimewire.Scalar_NullValue{NullValue: true}
	case string:
		out.Kind = &runtimewire.Scalar_Text{Text: v}
	case bool:
		out.Kind = &runtimewire.Scalar_Boolean{Boolean: v}
	case json.Number:
		n, err := v.Float64()
		if err != nil {
			return nil, err
		}
		out.Kind = &runtimewire.Scalar_Number{Number: n}
	default:
		val := reflect.ValueOf(value)
		switch val.Kind() {
		case reflect.Float32, reflect.Float64:
			out.Kind = &runtimewire.Scalar_Number{Number: val.Float()}
		case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
			out.Kind = &runtimewire.Scalar_Number{Number: float64(val.Int())}
		case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
			out.Kind = &runtimewire.Scalar_Number{Number: float64(val.Uint())}
		default:
			return nil, fmt.Errorf("unsupported runtime scalar %T", value)
		}
	}
	return out, nil
}

func protobufRuntimeFrame(frame *runtimeDeltaFrame) (*runtimewire.RuntimeFrame, error) {
	out := &runtimewire.RuntimeFrame{Epoch: frame.Epoch, Sequence: frame.Sequence, Version: frame.Version, Reset_: frame.Kind == "reset", Removed: frame.Removed, MetaJson: frame.Meta}
	add := func(v streamValue) (*runtimewire.RuntimeValue, error) {
		value, err := protobufScalar(v.Value)
		if err != nil {
			return nil, err
		}
		raw, err := protobufScalar(v.Raw)
		if err != nil {
			return nil, err
		}
		item := &runtimewire.RuntimeValue{PointId: v.PointID, Value: value, Raw: raw, Quality: v.Quality, SourceTime: v.SourceTime.Format(time.RFC3339Nano), ReceivedTime: v.ReceivedTime.Format(time.RFC3339Nano)}
		out.Values = append(out.Values, item)
		return item, nil
	}
	switch values := frame.Values.(type) {
	case []storage.Sample:
		for _, v := range values {
			item, err := add(streamValue{v.PointID, v.Value, v.Raw, v.Quality, v.SourceTime, v.ReceivedTime})
			if err != nil {
				return nil, err
			}
			item.Seq, item.Station, item.Name, item.Unit, item.Version = v.Seq, v.Station, v.Name, v.Unit, v.Version
		}
	case []streamValue:
		for _, v := range values {
			if _, err := add(v); err != nil {
				return nil, err
			}
		}
	default:
		return nil, errors.New("invalid runtime values")
	}
	return out, nil
}
